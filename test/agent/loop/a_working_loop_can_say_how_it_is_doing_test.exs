defmodule OptimalSystemAgent.Agent.Loop.AWorkingLoopCanSayHowItIsDoingTest do
  @moduledoc """
  A session that is working must still be able to answer "how are you doing".

  `Agent.Loop` runs the ENTIRE turn synchronously inside
  `handle_call({:process, ...})` — `TurnPipeline.run` -> `ReactLoop.run` ->
  `ToolOrchestrator.dispatch`, all on the GenServer's own stack. While that
  runs, the process mailbox is not served, so every other `handle_call` queues
  behind the whole turn.

  That is not a hypothetical. Tool execution is deliberately unbounded
  (`config :tool_timeout_ms, :infinity`, locked by `LongRunningToolTest` after a
  three-agent dispatch was killed at a ten-minute ceiling and lost its turn's
  work), and it SHOULD be: a wall-clock cap punishes work for taking long. So
  the blocking stretch here has no upper bound by design, and the only question
  is whether the session can be observed during it.

  It could not. `Loop.get_state/1` is a `GenServer.call` with the default 5s
  timeout wrapped in `catch :exit, _ -> {:error, :not_found}`, so a session busy
  doing exactly what it was asked to do reported itself as NOT EXISTING — the
  same shape as a dead session, from the one process that knew better. Every
  reader inherits it: `/status`, the HTTP progress route, the orchestrator's
  view of a subagent.

  The cancel flag was already exempt from this, and deliberately: it lives in
  ETS precisely because "ETS reads work even while handle_call blocks the
  mailbox" (`loop.ex`). This locks the same property for the thing a user asks
  for far more often than a cancel — the state.

  Nothing here asserts a bound on how long a turn may take. The turn is allowed
  to run forever; it is not allowed to be unobservable while it does.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Test.MockProvider

  # Long enough that the 5s `GenServer.call` default expires inside it, so the
  # test measures the blocked mailbox and not a lucky race. Not a bound on
  # anything — the real case is unbounded.
  @moduletag timeout: 180_000

  @block_ms 8_000

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_module = Application.get_env(:optimal_system_agent, :mock_provider_module)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_module, MockProvider)
    MockProvider.reset()

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :mock_provider_sleep_ms)

      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      if prev_module,
        do: Application.put_env(:optimal_system_agent, :mock_provider_module, prev_module),
        else: Application.delete_env(:optimal_system_agent, :mock_provider_module)
    end)

    session = "busy-loop-" <> Integer.to_string(System.unique_integer([:positive]))

    # Provider/model are pinned on the LOOP, not just in app env. `Loop.init/1`
    # resolves a provider once at start; without these the session came up on
    # whatever the machine's default is (observed: `:ollama`), the mock's sleep
    # never ran, and the turn finished before it could be observed — a green
    # test measuring nothing.
    :ok =
      SessionManager.ensure_loop(session,
        user_id: "test",
        working_dir: File.cwd!(),
        provider: :mock,
        model: "mock-model-1.0"
      )

    on_exit(fn -> SessionManager.cancel(session) end)

    {:ok, session: session}
  end

  test "a session mid-turn reports its state instead of reporting itself missing", %{
    session: session
  } do
    # A healthy, answerable session before the turn — so a failure below is
    # about being BUSY and not about the fixture.
    assert {:ok, idle_snap} = Loop.get_state(session)
    assert idle_snap.session_id == session

    # Put the loop into a long blocking stretch inside `handle_call`. The mock
    # provider sleeps in-band, which is the same shape as an unbounded tool:
    # the GenServer's stack is occupied and its mailbox is not served.
    Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, @block_ms)

    turn =
      Task.async(fn ->
        Loop.process_message(session, "block for a while", timeout: :infinity)
      end)

    # Let the turn actually enter the blocking stretch. Until the call is
    # received the mailbox is still free and the assertion would be vacuous.
    Process.sleep(1_500)

    # THE PROPERTY. Before the fix this is `{:error, :not_found}` — a live,
    # working session denying its own existence to the only API that asks.
    case Loop.get_state(session) do
      {:ok, snap} ->
        assert snap.session_id == session,
               "the snapshot must identify the session it describes: #{inspect(snap)}"

        assert snap.status in [:working, :running, :thinking, :busy],
               "a session inside a turn must say it is working, not #{inspect(snap.status)}"

      {:error, reason} ->
        flunk("""
        a session that is mid-turn could not report its state: #{inspect(reason)}

        This is the defect. The turn runs on the GenServer's own stack, so the
        `get_state` call sat in an unserved mailbox until its 5s default
        expired, and `Loop.get_state/1` translated that exit into
        `{:error, :not_found}` — indistinguishable from a session that is gone.
        Tool execution is unbounded by design, so this stretch has no ceiling:
        the session is unobservable for as long as the work takes.
        """)
    end

    # The observation is made; let the remaining round-trips run at speed. The
    # blocking stretch was the subject, not the rest of the turn.
    Application.delete_env(:optimal_system_agent, :mock_provider_sleep_ms)

    # And the turn itself is untouched by having been observed.
    assert Task.await(turn, 120_000)
  end

  test "cancellation still reaches a blocked loop, and is not what makes it observable", %{
    session: session
  } do
    # The cancel flag already bypassed the mailbox via ETS. Asserted here so the
    # fix above cannot be mistaken for having introduced it, and so a future
    # change that routes cancel through the mailbox fails loudly.
    Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, @block_ms)

    turn =
      Task.async(fn ->
        Loop.process_message(session, "block for a while", timeout: :infinity)
      end)

    Process.sleep(1_500)

    # Reaches the process without needing it to serve its mailbox.
    assert :ok = Loop.cancel(session)

    # The turn ends rather than running to completion of the block.
    Application.delete_env(:optimal_system_agent, :mock_provider_sleep_ms)
    assert Task.await(turn, 120_000)
  end
end
