defmodule OptimalSystemAgent.Agent.SubagentFlowTest do
  @moduledoc """
  The four places a delegation stopped reaching the user.

  Each block below pins one of them. They are grouped in a single file because
  they are one failure, seen from four sides: work was happening, and the
  session the human was looking at could not tell them about it, could not be
  told anything by them, and — twice — reported something that was not true.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.BackgroundNotifier
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Tools.Builtins.Delegate

  setup do
    RunStore.init_store()
    :ok
  end

  defp uid, do: Integer.to_string(System.unique_integer([:positive]))

  # Move a run's clock back so the warm-up and spacing windows can be crossed
  # without sleeping through them. `Discipline.check/2` takes an injectable
  # `now_ms`, but `Handler.execute/2` reads the real clock, so the only way to
  # exercise the SEND path past the warm-up is to age the run itself.
  defp backdate_run(agent_id, ms) do
    run = RunStore.get(agent_id)
    aged = %{run | started_at: DateTime.add(run.started_at, -ms, :millisecond)}
    :ets.insert(RunStore, {agent_id, aged})
    :ok
  end

  # ---------------------------------------------------------------------------
  # 1 — a delegation must not block the parent's turn
  # ---------------------------------------------------------------------------

  describe "delegation posture" do
    test "an unclassified delegation runs in the background" do
      # The whole point of the feature is that the user can keep typing. A
      # foreground delegate blocks the parent INSIDE its tool phase, and the
      # steer drain, the task-notification drain and cancellation all live at
      # the TOP of a ReAct iteration — so for the child's entire life (hours,
      # by design) the parent's loop services none of them.
      assert Delegate.Handler.background?(%{"task" => "audit the auth module"}, %{}) == true
    end

    test "an explicit background flag wins in either direction" do
      config = %{background: true}

      assert Delegate.Handler.background?(%{"background" => false}, config) == false
      assert Delegate.Handler.background?(%{"background" => true}, %{background: false}) == true
    end

    test "an agent definition that asks to be joined still is" do
      # `background: false` in a definition is a deliberate opt-out and has to
      # survive the default flip — which is why the resolution is by key
      # PRESENCE, not by truthiness.
      assert Delegate.Handler.background?(%{}, %{background: false}) == false
    end
  end

  # ---------------------------------------------------------------------------
  # 2 — a steer must reach whoever is actually working
  # ---------------------------------------------------------------------------

  describe "steer targets" do
    test "a plain session is its own only target" do
      sid = "sess-plain-#{uid()}"
      assert Loop.steer_targets(sid) == [sid]
    end

    test "a steer reaches running subagents, and the session stays first" do
      parent = "sess-parent-#{uid()}"
      child = "agent:#{parent}:1"
      grandchild = "agent:#{child}:1"

      RunStore.start_run(%{agent_id: child, parent_session_id: parent, role: "researcher"})
      RunStore.start_run(%{agent_id: grandchild, parent_session_id: child, role: "fixer"})

      targets = Loop.steer_targets(parent)

      assert hd(targets) == parent, "the session itself must remain the first target"
      assert child in targets, "a running subagent is where the work actually is"
      assert grandchild in targets, "and so is its own child"
    end

    test "a finished subagent is not a steer target" do
      parent = "sess-done-#{uid()}"
      child = "agent:#{parent}:1"

      RunStore.start_run(%{agent_id: child, parent_session_id: parent, role: "researcher"})

      RunStore.complete(child, %{
        agent_id: child,
        status: :completed,
        summary: "done",
        duration_ms: 5
      })

      # There is no loop left to fold a directive into; queueing for it would
      # strand the steer in ETS until the table is swept.
      refute child in Loop.steer_targets(parent)
    end

    test "queueing a steer actually enqueues it for a running child" do
      parent = "sess-queue-#{uid()}"
      child = "agent:#{parent}:1"
      RunStore.start_run(%{agent_id: child, parent_session_id: parent, role: "researcher"})

      Loop.steer(parent, "stop reading tests, read the handler")

      # Drained per-session and destructively, so each recipient gets exactly
      # its own copy.
      assert Loop.Steer.drain(child) == ["stop reading tests, read the handler"]
      assert Loop.Steer.drain(parent) == ["stop reading tests, read the handler"]
      assert Loop.Steer.drain(child) == []
    end
  end

  # ---------------------------------------------------------------------------
  # 3 — an unmeasured counter is not a zero counter
  # ---------------------------------------------------------------------------

  describe "reported usage" do
    test "a run with no row reports duration only" do
      usage = Orchestrator.reported_usage(nil, 91_000)

      assert usage == %{duration_ms: 91_000}

      refute Map.has_key?(usage, :total_tokens),
             "a literal 0 decodes as Some(0) in the TUI and ERASES the counters " <>
               "accumulated from progress events — the panel showed a 40k/12 teammate " <>
               "finishing as '0 tools · 0 tokens'"

      refute Map.has_key?(usage, :tool_uses)
    end

    test "a run with a row reports its real counters" do
      usage = Orchestrator.reported_usage(%{tokens_used: 40_123, tool_count: 12}, 91_000)

      assert usage == %{duration_ms: 91_000, total_tokens: 40_123, tool_uses: 12}
    end

    test "a genuine zero is still reported" do
      usage = Orchestrator.reported_usage(%{tokens_used: 0, tool_count: 0}, 5)

      assert usage == %{duration_ms: 5, total_tokens: 0, tool_uses: 0},
             "measured-and-zero is a fact; it is only the UNMEASURED case that is omitted"
    end

    test "the model-facing usage line survives the omission" do
      # A whole-map pattern match on the three-key shape would miss a partial
      # map and hand the model an inspected term instead of numbers.
      assert BackgroundNotifier.format_usage(%{duration_ms: 91_000}) == "duration_ms=91000"

      assert BackgroundNotifier.format_usage(%{
               total_tokens: 40_123,
               tool_uses: 12,
               duration_ms: 91_000
             }) == "total_tokens=40123 tool_uses=12 duration_ms=91000"

      assert BackgroundNotifier.format_usage(%{}) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # 4 — a subagent blocked on approval must be visible
  # ---------------------------------------------------------------------------

  describe "permission request routing" do
    test "a top-level session publishes only to itself" do
      sid = "sess-top-#{uid()}"
      assert ToolExecutor.permission_topics(sid) == [sid]
    end

    test "a subagent's request also reaches the root session" do
      root = "sess-root-#{uid()}"
      child = "agent:#{root}:1"
      grandchild = "agent:#{child}:1"

      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "researcher"})
      RunStore.start_run(%{agent_id: grandchild, parent_session_id: child, role: "fixer"})

      topics = ToolExecutor.permission_topics(grandchild)

      assert hd(topics) == grandchild,
             "a client attached directly to the subagent must keep working"

      assert child in topics
      assert root in topics, "the root is the only session the TUI is actually streaming"
    end

    test "the request the root receives is the one the child is waiting on" do
      root = "sess-live-#{uid()}"
      child = "agent:#{root}:1"
      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "researcher"})

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{root}")

      state = %{session_id: child, permission_tier: :subagent, messages: []}
      request_id = "perm_test_#{uid()}"

      ToolExecutor.emit_permission_required(
        state,
        request_id,
        %{id: "call_1", name: "shell_execute", arguments: %{}},
        %{args: "rm -rf build", kind: "shell"}
      )

      assert_receive {:osa_event, ev}, 1_000

      assert ev.event == :permission_required
      assert ev.request_id == request_id
      assert ev.tool == "shell_execute"

      # Attribution: the root session never made this call, so the dialog has
      # to be able to say who did.
      assert ev.agent_id == child
      assert ev.display_name == "researcher"
    end

    test "an answer given at the root satisfies the child's wait" do
      # PermissionBroker is keyed by request_id alone, which is what makes the
      # re-broadcast sufficient — no session plumbing is needed on the reply.
      request_id = "perm_answer_#{uid()}"
      child = "agent:sess-answer-#{uid()}:1"

      OptimalSystemAgent.Agent.Loop.PermissionBroker.respond(request_id, "allow")

      assert {:ok, %{decision: :allow_once}} =
               OptimalSystemAgent.Agent.Loop.PermissionBroker.await(child, request_id)
    end
  end

  # ---------------------------------------------------------------------------
  # 5 — a failure must be reported as a failure
  # ---------------------------------------------------------------------------

  describe "the completion account, by status" do
    alias OptimalSystemAgent.Agent.TaskNotifications

    test "a failed task is not handed to the model as an account of work done" do
      xml =
        TaskNotifications.to_xml(%{
          task_id: "agent:s1:1",
          status: :failed,
          summary: "process crashed/exited: killed",
          output_file: "/tmp/x.md"
        })

      # The success instruction asks what the task "found" and "changed" —
      # questions that presuppose work happened. Answered faithfully about a
      # crashed run, they produce a confident account of nothing.
      refute xml =~ TaskNotifications.completion_instruction(),
             "a crashed task must not carry the give-an-account-of-what-it-found text"

      assert xml =~ TaskNotifications.failure_instruction()
      assert xml =~ "did NOT succeed"
      assert xml =~ "PLAINLY and FIRST"
      assert xml =~ "do NOT quietly"
    end

    test "a stalled or cancelled task is treated the same way" do
      for status <- [:stalled, :cancelled, :timeout, "failed"] do
        xml = TaskNotifications.to_xml(%{task_id: "t", status: status, summary: "x"})

        assert xml =~ TaskNotifications.failure_instruction(),
               "status #{inspect(status)} describes output the model must not present as work"
      end
    end

    test "a successful task keeps the account instruction" do
      for status <- [:completed, :done, "ok", nil] do
        xml = TaskNotifications.to_xml(%{task_id: "t", status: status, summary: "x"})
        assert xml =~ TaskNotifications.completion_instruction()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 6 — the subagent voice: reachable, attributed, and rationed
  # ---------------------------------------------------------------------------

  describe "the subagent voice" do
    alias OptimalSystemAgent.Tools.Builtins.SendMessage.{Constants, Discipline}
    alias OptimalSystemAgent.Tools.Builtins.SendMessage.Handler, as: SendMessage

    test "a subagent can address the user, and a top-level session cannot" do
      root = "sess-voice-#{uid()}"
      child = "agent:#{root}:1"
      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "researcher"})

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{root}")

      # Past the warm-up, or the discipline (correctly) refuses.
      Discipline.reset(child)
      backdate_run(child, Constants.warmup_ms() + 1_000)

      {:ok, reply} =
        SendMessage.execute(
          %{"to" => "user", "message" => "the auth module has no tests at all"},
          %{session_id: child}
        )

      assert reply =~ "Message sent"
      assert_receive {:osa_event, %{type: :agent_message} = ev}, 1_000

      assert ev.text =~ "no tests at all"

      # Attribution: `agent:<sess>:1` used to render as "@1", which tells the
      # reader nothing about who is speaking or why they should care.
      assert ev.from == "researcher"

      # A session with no parent has nobody to address, and is told so rather
      # than silently succeeding.
      {:ok, orphan_reply} =
        SendMessage.execute(
          %{"to" => "user", "message" => "hello"},
          %{session_id: "sess-orphan-#{uid()}"}
        )

      assert orphan_reply =~ "no parent"
    end

    test "the budget is spent, not silently dropped" do
      root = "sess-budget-#{uid()}"
      child = "agent:#{root}:1"
      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "researcher"})
      Discipline.reset(child)

      started = DateTime.to_unix(RunStore.get(child).started_at, :millisecond)
      past_warmup = started + Constants.warmup_ms() + 1

      assert Discipline.check(child, past_warmup) == :ok

      # Spacing: a second message immediately after the first reads as a stream.
      assert {:refused, spacing} = Discipline.check(child, past_warmup + 1_000)
      assert spacing =~ "spaced at least"

      # Past the spacing floor, the second of two is allowed...
      spaced = past_warmup + Constants.min_spacing_ms() + 1
      assert Discipline.check(child, spaced) == :ok

      # ...and the third is refused WITH A REASON THE MODEL CAN READ. A model
      # that thinks it spoke and did not will simply keep trying.
      assert {:refused, budget} =
               Discipline.check(child, spaced + Constants.min_spacing_ms() + 1)

      assert budget =~ "messages for this run"
    end

    test "nothing is said in the warm-up" do
      root = "sess-warm-#{uid()}"
      child = "agent:#{root}:1"
      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "researcher"})
      Discipline.reset(child)

      started = DateTime.to_unix(RunStore.get(child).started_at, :millisecond)

      assert {:refused, reason} = Discipline.check(child, started + 1_000)
      assert reason =~ "silent by design"
    end

    test "the user's own channel is never rationed or clipped" do
      plain = "sess-plain-voice-#{uid()}"
      long = String.duplicate("x", Constants.max_message_chars() * 2)

      refute Discipline.governed?(plain)
      assert Discipline.check(plain) == :ok
      assert Discipline.truncate(long, plain) == long
    end

    test "a subagent's message is cut, not rejected" do
      root = "sess-trunc-#{uid()}"
      child = "agent:#{root}:1"
      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "researcher"})

      long = String.duplicate("x", Constants.max_message_chars() * 2)
      cut = Discipline.truncate(long, child)

      # Rejecting would throw the lead away too, and burn one of only two
      # chances to say anything.
      assert String.length(cut) == Constants.max_message_chars()
      assert String.ends_with?(cut, "…")
    end

    test "a parked message expires instead of living forever in ETS" do
      target = "agent:sess-expire-#{uid()}:1"

      if :ets.whereis(Constants.pending_table()) == :undefined do
        :ets.new(Constants.pending_table(), [:bag, :public, :named_table])
      end

      :ets.insert(
        Constants.pending_table(),
        {target,
         %{
           from: "x",
           content: "stale",
           timestamp: System.system_time(:millisecond) - Constants.pending_ttl_ms() - 1_000
         }}
      )

      # The bag is written by the SENDER and drained by the RECIPIENT's loop, so
      # a message to an agent that crashed was never drained by anything.
      assert SendMessage.drain_pending_messages(target) == []
    end
  end
end
