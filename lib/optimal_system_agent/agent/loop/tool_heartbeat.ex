defmodule OptimalSystemAgent.Agent.Loop.ToolHeartbeat do
  @moduledoc """
  Emits liveness frames for a running tool without changing its timeout policy.

  Heartbeats let the TUI distinguish a long-running call from a dead backend.
  The first frame at the stall threshold is marked `stalled`, but OSA does not
  kill the tool because many builds and remote operations are legitimately long.
  """

  require Logger

  @interval_ms 10_000
  @stalled_ms 30_000

  @spec start(map(), map()) :: pid()
  def start(tool_call, state), do: start(tool_call, state, [])

  @doc false
  @spec start(map(), map(), keyword()) :: pid()
  def start(tool_call, state, opts) do
    owner = self()
    started = System.monotonic_time(:millisecond)
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)
    stalled_ms = Keyword.get(opts, :stalled_ms, @stalled_ms)

    spawn(fn ->
      ref = Process.monitor(owner)
      loop(ref, owner, tool_call, state, started, false, interval_ms, stalled_ms)
    end)
  end

  @spec stop(pid() | nil) :: :ok
  def stop(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  def stop(_), do: :ok

  defp loop(ref, owner, tool_call, state, started, stalled_sent, interval_ms, stalled_ms) do
    receive do
      :stop ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        :ok
    after
      interval_ms ->
        elapsed_ms = System.monotonic_time(:millisecond) - started
        stalled = elapsed_ms >= stalled_ms
        emit(tool_call, state, elapsed_ms, stalled and not stalled_sent)

        loop(
          ref,
          owner,
          tool_call,
          state,
          started,
          stalled_sent or stalled,
          interval_ms,
          stalled_ms
        )
    end
  end

  defp emit(tool_call, state, elapsed_ms, stalled) do
    payload = %{
      type: :tool_heartbeat,
      name: tool_call.name,
      tool_call_id: tool_call.id,
      elapsed_ms: elapsed_ms,
      stalled: stalled,
      session_id: state.session_id
    }

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event, payload}
    )

    :telemetry.execute(
      [:osa, :tools, :heartbeat],
      %{count: 1, elapsed_ms: elapsed_ms, stalled: if(stalled, do: 1, else: 0)},
      %{tool: tool_call.name, session_id: state.session_id}
    )
  rescue
    error ->
      Logger.error("[tool_heartbeat] emit failed: #{Exception.message(error)}")
      :ok
  end
end
