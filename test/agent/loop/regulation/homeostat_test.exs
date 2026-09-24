defmodule OptimalSystemAgent.Agent.Loop.Regulation.HomeostatTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Regulation.Homeostat
  alias OptimalSystemAgent.Agent.Loop.Regulation.Signals

  @key :regulation_homeostat

  setup do
    original = Application.get_env(:optimal_system_agent, @key)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:optimal_system_agent, @key),
        else: Application.put_env(:optimal_system_agent, @key, original)
    end)

    :ok
  end

  defp sid, do: "homeostat-#{System.unique_integer([:positive])}"

  defp signals(overrides \\ []) do
    Map.merge(
      %{
        probe_streak: 0,
        probe_tool: nil,
        stall_checkpoints: 0,
        reasoning_only_streak: 0,
        recovery_attempts: 0,
        recovery_ratio: 0.0,
        graded_escalation: 0,
        escalation_ratio: 0.0,
        reasoning_overflow_ms: nil,
        wait_ms: 0,
        surprises: 0,
        no_disk_change?: true,
        elapsed_ms: 0,
        cost_this_turn_usd: 0.0
      },
      Map.new(overrides)
    )
  end

  describe "cost variable" do
    test "high band requires BOTH spend above the threshold AND no disk change" do
      Application.put_env(:optimal_system_agent, @key, cost_no_progress_usd: 0.10)

      {_state, report} =
        Homeostat.regulate([], [], %{session_id: sid()}, signals(cost_this_turn_usd: 0.50))

      assert report.cost.band == :high
    end

    test "ok band when the spend paid for an actual edit" do
      Application.put_env(:optimal_system_agent, @key, cost_no_progress_usd: 0.10)

      {_state, report} =
        Homeostat.regulate(
          [],
          [],
          %{session_id: sid()},
          signals(cost_this_turn_usd: 0.50, no_disk_change?: false)
        )

      assert report.cost.band == :ok
    end
  end

  describe "error rate variable" do
    test "high band once the rolling window crosses the ratio, with a minimum sample size" do
      Application.put_env(:optimal_system_agent, @key,
        error_rate_window: 10,
        error_rate_high: 0.5
      )

      call = %{id: "c", name: "shell_execute", arguments: %{"command" => "false"}}
      error_result = [{call, {%{}, "Exit 1:\nboom"}}]

      state = %{session_id: sid()}
      {state, report1} = Homeostat.regulate(error_result, [call], state, signals())
      assert report1.error.band == :ok, "one sample must not read as 100% erroring"

      {state, report2} = Homeostat.regulate(error_result, [call], state, signals())
      assert report2.error.band == :ok, "two samples must not yet meet the minimum window size"

      {_state, report3} = Homeostat.regulate(error_result, [call], state, signals())
      assert report3.error.band == :high
    end

    test "ok band when calls are clean" do
      call = %{id: "c", name: "file_read", arguments: %{"path" => "/tmp/x"}}
      ok_result = [{call, {%{}, "file contents"}}]

      {_state, report} = Homeostat.regulate(ok_result, [call], %{session_id: sid()}, signals())
      assert report.error.band == :ok
    end
  end

  describe "progress variable" do
    test "idle streak rises with no new tool, no write, no passing check, and nudges once at the threshold" do
      Application.put_env(:optimal_system_agent, @key, progress_low_streak: 3)

      call = %{id: "c", name: "file_read", arguments: %{"path" => "/tmp/x"}}
      result = [{call, {%{}, "same content"}}]

      state = %{
        session_id: sid(),
        messages: [],
        # Seeded to match `distinct_tools_seen`'s size: this call's tool has
        # already been seen before this test starts, so it does not itself
        # register as a "newly tried tool" on the very first iteration below.
        distinct_tools_seen: MapSet.new(["file_read"]),
        regulation_prev_distinct_tool_count: 1
      }

      {state, r1} = Homeostat.regulate(result, [call], state, signals(no_disk_change?: true))
      assert r1.progress.idle_streak == 1
      refute r1.progress.nudged?

      {state, r2} = Homeostat.regulate(result, [call], state, signals(no_disk_change?: true))
      assert r2.progress.idle_streak == 2

      {state, r3} = Homeostat.regulate(result, [call], state, signals(no_disk_change?: true))
      assert r3.progress.idle_streak == 3
      assert r3.progress.band == :low
      assert r3.progress.nudged?

      reorientation? =
        Enum.any?(state.messages, fn m ->
          m.role == "system" and String.contains?(m.content, "no measured progress")
        end)

      assert reorientation?, "expected a single reorientation note injected at the crossing"
    end

    test "a real write resets the idle streak" do
      Application.put_env(:optimal_system_agent, @key, progress_low_streak: 3)

      read_call = %{id: "c1", name: "file_read", arguments: %{"path" => "/tmp/x"}}
      write_call = %{id: "c2", name: "file_edit", arguments: %{"path" => "/tmp/x"}}

      state = %{
        session_id: sid(),
        messages: [],
        distinct_tools_seen: MapSet.new(["file_read", "file_edit"]),
        regulation_prev_distinct_tool_count: 2
      }

      {state, r1} =
        Homeostat.regulate(
          [{read_call, {%{}, "same"}}],
          [read_call],
          state,
          signals(no_disk_change?: true)
        )

      assert r1.progress.idle_streak == 1

      {_state, r2} =
        Homeostat.regulate(
          [{write_call, {%{}, "Edited /tmp/x"}}],
          [write_call],
          state,
          signals(no_disk_change?: false)
        )

      assert r2.progress.idle_streak == 0
    end

    test "a newly-tried tool counts as progress" do
      state = %{
        session_id: sid(),
        messages: [],
        distinct_tools_seen: MapSet.new(["file_read", "shell_execute"]),
        regulation_prev_distinct_tool_count: 1
      }

      call = %{id: "c", name: "shell_execute", arguments: %{"command" => "pwd"}}

      {_state, report} =
        Homeostat.regulate(
          [{call, {%{}, "/tmp"}}],
          [call],
          state,
          signals(no_disk_change?: true)
        )

      assert report.progress.idle_streak == 0
    end

    test "a recognised check command that ran clean counts as progress" do
      call = %{id: "c", name: "shell_execute", arguments: %{"command" => "mix test"}}
      result = [{call, {%{}, "1 test, 0 failures"}}]

      state = %{
        session_id: sid(),
        messages: [],
        # Seeded so the tool itself is not ALSO "newly tried" — isolates that
        # progress here comes from the recognised, clean check command.
        distinct_tools_seen: MapSet.new(["shell_execute"]),
        regulation_prev_distinct_tool_count: 1
      }

      {_state, report} =
        Homeostat.regulate(result, [call], state, signals(no_disk_change?: true))

      assert report.progress.idle_streak == 0
    end
  end

  describe "context variable" do
    test "reports the ok band under the high-water mark" do
      Application.put_env(:optimal_system_agent, @key, context_high_pct: 85.0)

      state = %{session_id: sid(), messages: [], model: "unknown-test-model", provider: :mock}
      {_state, report} = Homeostat.regulate([], [], state, signals())

      # An unresolvable model/provider reads as 0% utilization (never crashes,
      # never fabricates a number) — well under the high-water mark either way.
      assert report.context.band == :ok
      assert report.context.corrected? == false
    end
  end

  test "disabled config short-circuits every variable to :ok with no side effects" do
    Application.put_env(:optimal_system_agent, @key, enabled: false)

    state = %{session_id: sid(), messages: []}
    {state, report} = Homeostat.regulate([], [], state, signals(cost_this_turn_usd: 999.0))

    assert report.cost.band == :ok
    assert report.progress.band == :ok
    assert report.error.band == :ok
    assert report.context.band == :ok
    assert state.messages == []
  end

  test "Signals.t() shape matches what Homeostat expects (contract check)" do
    call = %{id: "c", name: "file_read", arguments: %{"path" => "/tmp/x"}}
    results = [{call, {%{}, "content"}}]
    real_signals = Signals.collect(results, [call], %{session_id: sid()})

    {_state, report} = Homeostat.regulate(results, [call], %{session_id: sid()}, real_signals)
    assert report.cost.band in [:ok, :high]
  end
end
