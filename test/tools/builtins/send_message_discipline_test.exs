defmodule OptimalSystemAgent.Tools.Builtins.SendMessageDisciplineTest do
  @moduledoc """
  The subagent voice: addressing, attribution, and rate discipline.

  The pipe already worked before any of this — `send_message` broadcast, and the
  TUI rendered `› Message from @x`. What these tests pin down is the part that
  decides whether the channel is worth having at all: that a subagent CAN reach
  the user, that the user can tell who is speaking, and that a subagent which
  wants to speak every thirty seconds is stopped and TOLD it was stopped.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.Builtins.SendMessage.{Constants, Discipline, Handler}
  alias OptimalSystemAgent.Tools.UseContext

  @parent "parent-session-#{System.unique_integer([:positive])}"

  setup do
    child = "agent:#{@parent}:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Discipline.reset(child)
      safe_ets_delete(RunStore, child)
    end)

    %{child: child}
  end

  defp safe_ets_delete(table, key) do
    :ets.delete(table, key)
  rescue
    _ -> :ok
  end

  # A real subagent run (written by the real `RunStore.start_run/1`) whose start
  # is backdated by `age_ms`, so the warm-up window can be placed on either side
  # of "now" without sleeping through it.
  defp start_run!(child, age_ms) do
    RunStore.start_run(%{
      agent_id: child,
      parent_session_id: @parent,
      role: "explore",
      task: "look at the auth module"
    })

    run = RunStore.get(child)
    assert run, "RunStore.start_run/1 did not create a row"

    started = DateTime.add(DateTime.utc_now(), -age_ms, :millisecond)
    :ets.insert(RunStore, {child, %{run | started_at: started}})
    :ok
  end

  defp ctx(session_id), do: %UseContext{session_id: session_id}

  defp subscribe(session_id) do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
  end

  # ---------------------------------------------------------------------------
  # B1 — a child can name its parent
  # ---------------------------------------------------------------------------

  describe "B1: addressing the parent" do
    test "to: \"user\" resolves to the session that delegated this agent", %{child: child} do
      start_run!(child, Constants.warmup_ms() + 1_000)
      subscribe(@parent)

      assert {:ok, result} =
               Handler.execute(
                 %{"to" => "user", "message" => "the auth module has no tests at all"},
                 ctx(child)
               )

      assert result =~ @parent, "expected the send to resolve to the parent session"

      assert_receive {:osa_event,
                      %{type: :agent_message, session_id: @parent, text: text}},
                     1_000

      assert text =~ "no tests at all"
    end

    test "to: \"user\" from a session with no parent explains itself instead of 404ing" do
      # A top-level session is not a subagent; there is nobody above it.
      assert {:ok, result} =
               Handler.execute(
                 %{"to" => "user", "message" => "hello"},
                 ctx("top-level-#{System.unique_integer([:positive])}")
               )

      assert result =~ "no parent"
      refute result =~ "Use /agents"
    end
  end

  # ---------------------------------------------------------------------------
  # B2 — attribution reads as a name, not an ordinal
  # ---------------------------------------------------------------------------

  describe "B2: attribution" do
    test "the message is attributed to the agent's role, not the id's last segment",
         %{child: child} do
      start_run!(child, Constants.warmup_ms() + 1_000)
      subscribe(@parent)

      assert {:ok, _} =
               Handler.execute(%{"to" => "user", "message" => "heads up"}, ctx(child))

      assert_receive {:osa_event, %{type: :agent_message, from: from}}, 1_000

      ordinal = child |> String.split(":") |> List.last()

      assert from == "explore",
             "expected the run's role; got #{inspect(from)}"

      refute from == ordinal,
             "the last id segment is an ordinal, not a name — it tells the reader nothing"
    end
  end

  # ---------------------------------------------------------------------------
  # B4 — rate discipline
  # ---------------------------------------------------------------------------

  describe "B4: budget" do
    test "the third message is refused with a reason the model can read", %{child: child} do
      now = System.system_time(:millisecond)
      start_run!(child, Constants.warmup_ms() + 1_000)

      # Two sends, spaced past the minimum, both allowed.
      assert :ok = Discipline.check(child, now)
      assert :ok = Discipline.check(child, now + Constants.min_spacing_ms() + 1)

      # The third is refused — and the refusal is a message, not a silent drop.
      assert {:refused, reason} =
               Discipline.check(child, now + 10 * Constants.min_spacing_ms())

      assert reason =~ "#{Constants.max_messages_per_run()} messages"
      assert reason =~ "report"
      assert Discipline.sent_count(child) == Constants.max_messages_per_run()
    end

    test "a refused send does NOT broadcast", %{child: child} do
      start_run!(child, Constants.warmup_ms() + 1_000)
      subscribe(@parent)

      for n <- 1..Constants.max_messages_per_run() do
        # Spend the budget directly so the spacing rule doesn't mask the budget.
        assert :ok =
                 Discipline.check(
                   child,
                   System.system_time(:millisecond) + n * (Constants.min_spacing_ms() + 1)
                 )
      end

      assert {:ok, refusal} =
               Handler.execute(%{"to" => "user", "message" => "third thing"}, ctx(child))

      assert refusal =~ "messages"
      refute_receive {:osa_event, %{type: :agent_message}}, 300
    end
  end

  describe "B4: warm-up" do
    test "a message inside the warm-up window does not broadcast", %{child: child} do
      start_run!(child, 1_000)
      subscribe(@parent)

      assert {:ok, refusal} =
               Handler.execute(
                 %{"to" => "user", "message" => "I have started reading files"},
                 ctx(child)
               )

      assert refusal =~ "silent by design"
      refute_receive {:osa_event, %{type: :agent_message}}, 300

      # And it costs nothing: a refusal must not burn budget.
      assert Discipline.sent_count(child) == 0
    end
  end

  describe "B4: spacing" do
    test "a second message inside the spacing window does not broadcast", %{child: child} do
      start_run!(child, Constants.warmup_ms() + 1_000)
      subscribe(@parent)

      assert {:ok, first} =
               Handler.execute(%{"to" => "user", "message" => "first finding"}, ctx(child))

      assert first =~ @parent
      assert_receive {:osa_event, %{type: :agent_message}}, 1_000

      assert {:ok, refusal} =
               Handler.execute(%{"to" => "user", "message" => "second finding"}, ctx(child))

      assert refusal =~ "#{div(Constants.min_spacing_ms(), 1000)}s apart"
      refute_receive {:osa_event, %{type: :agent_message}}, 300
    end
  end

  describe "B4: truncation" do
    test "an over-long message is CUT, never rejected", %{child: child} do
      start_run!(child, Constants.warmup_ms() + 1_000)
      subscribe(@parent)

      long = String.duplicate("x", Constants.max_message_chars() * 3)

      assert {:ok, result} = Handler.execute(%{"to" => "user", "message" => long}, ctx(child))
      assert result =~ @parent, "truncation must not turn into rejection"

      assert_receive {:osa_event, %{type: :agent_message, text: text}}, 1_000
      assert String.length(text) == Constants.max_message_chars()
      assert String.ends_with?(text, "…")
    end

    test "a top-level sender is NOT truncated — that is the user's own channel" do
      long = String.duplicate("y", Constants.max_message_chars() * 2)
      assert Discipline.truncate(long, "top-level-session") == long
    end
  end

  describe "B4: scope" do
    test "a non-subagent sender is ungoverned" do
      top = "top-level-#{System.unique_integer([:positive])}"
      refute Discipline.governed?(top)

      for _ <- 1..(Constants.max_messages_per_run() + 3) do
        assert :ok = Discipline.check(top)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Parked-message expiry — the bag was unbounded
  # ---------------------------------------------------------------------------

  describe "parked-message expiry" do
    test "rows older than the TTL are swept and never delivered" do
      target = "stale-target-#{System.unique_integer([:positive])}"
      now = System.system_time(:millisecond)

      # The table is created lazily by the first send; make sure it exists.
      if :ets.whereis(Constants.pending_table()) == :undefined do
        :ets.new(Constants.pending_table(), [:bag, :public, :named_table])
      end

      :ets.insert(
        Constants.pending_table(),
        {target, %{from: "ghost", content: "ancient", timestamp: now - Constants.pending_ttl_ms() - 1}}
      )

      :ets.insert(
        Constants.pending_table(),
        {target, %{from: "live", content: "fresh", timestamp: now}}
      )

      assert Handler.sweep_pending(now) >= 1

      delivered = Handler.drain_pending_messages(target)
      contents = Enum.map(delivered, & &1.content)

      assert "fresh" in contents
      refute "ancient" in contents
    end
  end
end
