defmodule OptimalSystemAgent.Agent.Orchestrator.SubagentJoinRobustnessTest do
  @moduledoc """
  Delegation/subagent robustness regression tests (backend bug-hunt D1/D2):

    * D1 — a subagent stuck inside one long op (slow provider call) must
      surface as `{:error, :timeout}` within its configured join timeout,
      NOT hang the parent turn forever, and the stuck child's GenServer must
      actually be terminated afterward (no orphan).
    * D1 — an explicit `Loop.cancel/1` must unblock a parent that is
      genuinely blocked joining a subagent, even with a generous timeout
      that has not yet elapsed.
    * D2 — a timed-out/crashed subagent must be classified as a FAILURE
      (`{:error, _}`), never laundered into `{:ok, "[...]"}`, and must not
      be counted as a completed workstream by `run_parallel/3`.

  Uses `OptimalSystemAgent.Test.MockProvider`'s configurable
  `:mock_provider_sleep_ms` to deterministically simulate a subagent stuck
  inside a provider call, without any live network dependency.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_sleep = Application.get_env(:optimal_system_agent, :mock_provider_sleep_ms)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :mock_provider_sleep_ms)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      if prev_sleep,
        do: Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, prev_sleep)
    end)

    :ok
  end

  defp uniq(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  defp base_config(subagent_id, parent_id, overrides \\ %{}) do
    Map.merge(
      %{
        task: "say hello",
        parent_session_id: parent_id,
        agent_id: subagent_id,
        role: "tester",
        tier: :specialist,
        model: "mock-model-1.0",
        provider: :mock,
        working_dir: System.tmp_dir!()
      },
      overrides
    )
  end

  # Registry deregistration happens via the Registry's own monitor after the
  # terminated process actually dies — poll briefly instead of asserting in
  # the same instant termination is requested (avoids a flaky race under
  # async test load).
  defp assert_registry_empty(id, attempts \\ 20)

  defp assert_registry_empty(id, 0),
    do: assert(Registry.lookup(OptimalSystemAgent.SessionRegistry, id) == [])

  defp assert_registry_empty(id, attempts) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, id) do
      [] -> :ok
      _ -> Process.sleep(50) && assert_registry_empty(id, attempts - 1)
    end
  end

  # ── D1: real, configurable join timeout (foreground path) ────────────

  describe "run_subagent/1 — stuck child join timeout" do
    test "a subagent stuck in one long provider call times out instead of hanging forever" do
      # Sleep far longer than the join timeout below.
      Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, 5_000)

      parent_id = uniq("parent")
      subagent_id = uniq("agent:stuck")

      config =
        base_config(subagent_id, parent_id, %{
          # Real, small, configurable timeout — NOT :infinity.
          timeout_ms: 300
        })

      {elapsed_us, result} = :timer.tc(fn -> Orchestrator.run_subagent(config) end)
      elapsed_ms = div(elapsed_us, 1000)

      # D2: classified as a FAILURE, never laundered into {:ok, "..."}.
      assert {:error, :timeout} = result

      # Returned well within the 5s the mock is sleeping for — proves the
      # join is actually bounded, not silently falling through to :infinity.
      assert elapsed_ms < 3_000

      # The stuck child's GenServer must actually be terminated (no orphan
      # burning tokens after the parent has given up on it).
      assert_registry_empty(subagent_id)
    end
  end

  # ── D1: real, configurable join timeout (fan-out / run_parallel path) ─

  describe "run_parallel/3 — stuck teammate in a wave" do
    test "a stuck teammate times out and is NOT counted as completed" do
      Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, 5_000)

      parent_id = uniq("parent")
      subagent_id = uniq("agent:wave-stuck")

      config = base_config(subagent_id, parent_id, %{timeout_ms: 300})

      {elapsed_us, [result]} =
        :timer.tc(fn ->
          Orchestrator.run_parallel(parent_id, [config], await_timeout: 1_500)
        end)

      elapsed_ms = div(elapsed_us, 1000)

      assert {:error, :timeout} = result
      assert elapsed_ms < 3_000
    end
  end

  # ── D1: cancel actually unblocks a genuinely blocked parent ───────────

  describe "Loop.cancel/1 — unblocks a parent joined on a stuck subagent" do
    test "cancel force-terminates the stuck child, unblocking the waiting caller well before its timeout" do
      Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, 10_000)

      parent_id = uniq("parent")
      subagent_id = uniq("agent:cancel-target")

      # A GENEROUS join timeout (60s) so if the test passes, it can only be
      # because cancel unblocked it — not because the timeout backstop fired.
      config = base_config(subagent_id, parent_id, %{timeout_ms: 60_000})

      test_pid = self()

      {:ok, _waiter} =
        Task.start(fn ->
          result = Orchestrator.run_subagent(config)
          send(test_pid, {:waiter_done, result})
        end)

      # Give the subagent a moment to actually start and enter the sleeping
      # provider call before we cancel it.
      Process.sleep(300)

      Loop.cancel(subagent_id)

      assert_receive {:waiter_done, result}, 5_000
      assert {:error, :cancelled} = result

      assert_registry_empty(subagent_id)
    end
  end
end
