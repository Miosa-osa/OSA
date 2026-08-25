defmodule OptimalSystemAgent.Agent.Orchestrator.SubagentLingerWakeTest do
  @moduledoc """
  Cheaper agent wake (#3) — keep a just-finished subagent RESIDENT for a short
  TTL so a quick follow-up reuses the live Loop with its context already in
  memory, instead of the expensive terminate-then-restart-and-replay-transcript
  path.

  Three properties are locked here:

    1. **Default safety.** With `:subagent_linger_ms` unset / 0, a completed
       subagent's Loop is terminated immediately, exactly as before. Nothing
       lingers. This is the proof that the feature is inert unless opted in.

    2. **Resident reuse.** With linger enabled, a resume that arrives inside the
       TTL is served by the SAME live pid — no restart. Pid identity across the
       resume is the observable proof that no terminate + replay happened (a
       replay would kill the resident pid and spawn a fresh one under the same
       id).

    3. **Bounded residency.** With linger enabled and NO resume, the resident
       pid is terminated once the TTL elapses. A resident Loop is never held
       forever.

  Uses `OptimalSystemAgent.Test.MockProvider` so completion is deterministic and
  needs no network.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_linger = Application.get_env(:optimal_system_agent, :subagent_linger_ms)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :subagent_linger_ms)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      if prev_linger,
        do: Application.put_env(:optimal_system_agent, :subagent_linger_ms, prev_linger)
    end)

    :ok
  end

  defp uniq(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  defp config(subagent_id, parent_id, overrides \\ %{}) do
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

  defp live_pid(id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  # Poll until the id has no live Loop registered (termination is async — the
  # Registry drops the entry via its own monitor after the process dies).
  defp assert_registry_empty(id, attempts \\ 40)

  defp assert_registry_empty(id, 0),
    do: assert(Registry.lookup(OptimalSystemAgent.SessionRegistry, id) == [])

  defp assert_registry_empty(id, attempts) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, id) do
      [] -> :ok
      _ -> Process.sleep(25) && assert_registry_empty(id, attempts - 1)
    end
  end

  defp terminate_leftover(id) do
    case live_pid(id) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(OptimalSystemAgent.SessionSupervisor, pid)

      _ ->
        :ok
    end
  end

  describe "default (linger disabled)" do
    test "a completed subagent's Loop is terminated immediately, exactly as before" do
      # No :subagent_linger_ms set → default 0.
      assert Orchestrator.subagent_linger_ms() == 0

      parent_id = uniq("parent")
      subagent_id = uniq("agent:no-linger")

      assert {:ok, _summary} = Orchestrator.run_subagent(config(subagent_id, parent_id))

      # The child is gone the moment run_subagent returns — nothing resident.
      assert_registry_empty(subagent_id)
    end
  end

  describe "linger enabled — resident reuse" do
    test "a resume inside the TTL reuses the SAME live pid (no terminate, no replay)" do
      # Generous TTL so the resume comfortably lands inside the linger window.
      Application.put_env(:optimal_system_agent, :subagent_linger_ms, 60_000)

      parent_id = uniq("parent")
      subagent_id = uniq("agent:linger-reuse")

      on_exit(fn -> terminate_leftover(subagent_id) end)

      assert {:ok, _} = Orchestrator.run_subagent(config(subagent_id, parent_id))

      # Instead of being terminated, the Loop is held resident.
      pid1 = live_pid(subagent_id)
      assert is_pid(pid1) and Process.alive?(pid1)

      # A follow-up under the SAME id is the fast-wake path: run_subagent routes
      # it to the resident Loop. If it had gone through terminate + replay, pid1
      # would be dead and a fresh pid would own the id.
      assert {:ok, _} =
               Orchestrator.run_subagent(config(subagent_id, parent_id, %{task: "keep going"}))

      pid2 = live_pid(subagent_id)
      assert pid2 == pid1
      assert Process.alive?(pid2)
    end
  end

  describe "linger enabled — bounded residency" do
    test "with no resume, the resident pid is terminated once the TTL elapses" do
      Application.put_env(:optimal_system_agent, :subagent_linger_ms, 250)

      parent_id = uniq("parent")
      subagent_id = uniq("agent:linger-ttl")

      assert {:ok, _} = Orchestrator.run_subagent(config(subagent_id, parent_id))

      # Resident right after completion...
      pid = live_pid(subagent_id)
      assert is_pid(pid) and Process.alive?(pid)

      # ...and terminated after the TTL lapses with no resume.
      assert_registry_empty(subagent_id)
    end
  end
end
