defmodule OptimalSystemAgent.Test.MCPSessionCleanup do
  @moduledoc """
  Tears down a test-started `MCP.Client.ServerSession` WITHOUT leaking its
  discovered tools into the shared `{Tools.Registry, :mcp_tools}`
  `:persistent_term` aggregate.

  `ServerSession` unconditionally reports whatever tools it discovers to the
  singleton `MCP.Client.Manager` (`report_tools/2`), which keeps them in its
  own `tools_by_server` GenServer state and republishes the aggregate — this
  happens regardless of whether the session was started through the Manager
  or, as every MCP client test does, directly via `ServerSession.start_link/1`.
  `Process.exit(pid, :kill)` only kills the session process; it does nothing
  to Manager's state, so a fake test server's tools stay in the GLOBAL
  aggregate for every test that runs afterward, in any file, `async: false`
  or not — an order-dependent failure (test passes alone, fails in the full
  suite) that shows up as some OTHER test's mcp tool/count assertion picking
  up entries it never published itself.

  `kill_and_reload/1`:
    1. Kills the session (tolerantly — it may already be exiting).
    2. Waits for the `:DOWN` so the kill has actually landed.
    3. Calls `Manager.reload/0`, which reloads real on-disk MCP config and
       prunes `tools_by_server` to exactly those (real) server names —
       purging the fake one this test invented, ordered after any
       `report_tools` cast the dying session had already queued.

  Call this from `on_exit`, after any test/setup that gets a `ServerSession`
  through a real `tools/list` handshake (i.e. not sessions that only ever
  reach `:connecting`/`:dormant` and never report tools).
  """

  @spec kill_and_reload(pid()) :: :ok
  def kill_and_reload(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    try do
      OptimalSystemAgent.MCP.Client.Manager.reload()
    catch
      _, _ -> :ok
    end

    :ok
  end
end
