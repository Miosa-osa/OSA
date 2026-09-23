defmodule OptimalSystemAgent.Agent.Loop.PokeRebuildsStaleContextTest do
  @moduledoc """
  Regression test for the idle-poke path silently reusing a frozen system
  prompt from the last REAL turn.

  ## The bug

  `Agent.Context.build/1` (via `ReactLoop.cached_context/1`) freezes the whole
  system message — Soul's static base (which folds in `lean_system_prompt?/0`
  and `lean_prompt?/0`), world state, tasks, memory, everything — in the
  process dictionary under `:osa_system_msg_cache`, keyed on
  `{plan_mode, session_id, memory_version, channel}`. The ONLY thing that ever
  deletes that key is `TurnPipeline.clear_message_caches/0`, step 5 of the
  gate pipeline every EXTERNAL turn runs through
  (`handle_call({:process, ...})` -> `TurnPipeline.run/3`).

  `handle_cast(:poke, %{status: :idle} = state)` — the WS6 background-task
  reaction (a delegated subagent or backgrounded shell command finishing while
  the session is idle) — calls `run_and_reply/1` directly, which reaches the
  very same `cached_context/1`, but WITHOUT going through `TurnPipeline.run/3`
  first. Since none of `plan_mode`, `session_id`, `memory_version` or
  `channel` changed between the last real turn and the poke, the cache key is
  identical and `cached_context/1` returns a HIT — the synthetic turn replays
  the exact system message from the last real turn, verbatim, with no call to
  `Context.build/1` (hence no call to `Soul.static_base/1`, hence no chance to
  notice a `~/.osa/settings.json` edit, a `/lean-prompt` toggle, or anything
  else that changed since).

  On a live daemon with background jobs or delegated subagents keeping a
  session poke-cycled, this made ANY settings change invisible for as long as
  poke — not a fresh external message — kept driving the session.

  This test proves the property directly: `Context.build_count/0`'s backing
  counter (`Process.get(:osa_context_builds)`, readable externally via
  `Process.info(pid, :dictionary)`) must increase across a poke-triggered
  synthetic turn, exactly as it does across a real one.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.TaskNotifications
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_module = Application.get_env(:optimal_system_agent, :mock_provider_module)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_module, MockProvider)
    MockProvider.reset()

    on_exit(fn ->
      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      if prev_module,
        do: Application.put_env(:optimal_system_agent, :mock_provider_module, prev_module),
        else: Application.delete_env(:optimal_system_agent, :mock_provider_module)
    end)

    session = "poke-rebuild-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      SessionManager.ensure_loop(session,
        user_id: "test",
        working_dir: File.cwd!(),
        provider: :mock,
        model: "mock-model-1.0"
      )

    on_exit(fn ->
      TaskNotifications.drain(session)
      SessionManager.cancel(session)
    end)

    {:ok, session: session}
  end

  defp loop_pid(session) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  # `Context.build_count/0` reads `Process.get(:osa_context_builds, 0)` FROM
  # WHATEVER PROCESS calls it — useless from the test process. Process
  # dictionaries are readable cross-process via `Process.info/2`, which is
  # exactly what this needs: an external, non-invasive read of how many times
  # the loop process itself has called `Context.build/1`.
  defp context_build_count(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :osa_context_builds, 0)
      nil -> 0
    end
  end

  test "a poke-triggered synthetic turn rebuilds context instead of replaying a frozen one",
       %{session: session} do
    assert {:ok, _reply} = Loop.process_message(session, "hello", timeout: :infinity)

    pid = loop_pid(session)
    assert is_pid(pid), "loop process for #{session} not found in SessionRegistry"

    builds_after_real_turn = context_build_count(pid)

    assert builds_after_real_turn > 0,
           "the real turn itself never called Context.build/1 — fixture is not exercising " <>
             "the path under test"

    # Loop must be idle before poke's `%{status: :idle}` clause services it —
    # `process_message/3` above already returned, so the turn is over.
    assert {:ok, %{status: status}} = Loop.get_state(session)
    assert status not in [:working, :running, :thinking, :busy]

    :ok =
      TaskNotifications.queue(session, %{
        task_id: "bg-poke-repro",
        status: "completed",
        summary: "background job finished (regression fixture)"
      })

    :ok = Loop.poke(session)

    # `Loop.get_state/1` is a `GenServer.call`, which queues behind the cast
    # above in the same mailbox — waiting on it serializes the test on the
    # poke-triggered synthetic turn actually finishing before the assertion.
    assert {:ok, _snap} = Loop.get_state(session)

    builds_after_poke = context_build_count(pid)

    assert builds_after_poke > builds_after_real_turn,
           "poke-triggered synthetic turn reused the frozen system-prompt cache from the " <>
             "last real turn instead of calling Context.build/1 again — a background-task " <>
             "reaction never sees a ~/.osa/settings.json edit (lean_system_prompt included) " <>
             "made after the last real turn, for as long as poke keeps driving the session"
  end
end
