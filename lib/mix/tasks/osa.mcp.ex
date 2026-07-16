defmodule Mix.Tasks.Osa.Mcp do
  @moduledoc """
  Run OSA as an MCP server over stdio.

  Exposes every OSA tool (plus an `osa_ask` agent tool) to any MCP client
  that speaks JSON-RPC 2.0 over stdio — e.g. Claude Desktop. Add to a client's
  MCP config like:

      {
        "mcpServers": {
          "osa": { "command": "mix", "args": ["osa.mcp"], "cwd": "/path/to/OSA" }
        }
      }

  ## CRITICAL: stdout is the protocol channel

  stdin/stdout carry newline-delimited JSON-RPC. This task forces ALL logging
  to STDERR and writes nothing but JSON-RPC responses to stdout. Never add
  `IO.puts`/`IO.write` to stdout anywhere in the server path.

  ## Usage

      mix osa.mcp
  """
  use Mix.Task

  @shortdoc "Run OSA as an MCP server over stdio"

  @impl true
  def run(_args) do
    # 1. Route ALL log output to stderr BEFORE anything can log. stdout is
    #    reserved for the JSON-RPC channel.
    configure_logging_to_stderr()

    # 2. Boot the OSA application quietly.
    Mix.Task.run("app.start", [])

    # Re-assert stderr device after app.start (in case it reconfigured Logger).
    configure_logging_to_stderr()

    # 3. Start the stdio MCP server reading/writing the real stdio device.
    {:ok, _pid} = OptimalSystemAgent.MCP.Server.StdioServer.start_link(io: :stdio)

    # 4. Block forever — the server runs until stdin closes (EOF) or the
    #    process is killed. On EOF the StdioServer stops; we then exit.
    ref = Process.monitor(Process.whereis(OptimalSystemAgent.MCP.Server.StdioServer))

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  defp configure_logging_to_stderr do
    Logger.configure(level: :warning)

    # Point the default console backend at stderr. Works whether the backend
    # is the legacy :console backend or the new default handler.
    try do
      Logger.configure_backend(:console, device: :standard_error)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    try do
      :logger.update_handler_config(:default, :config, %{type: :standard_error})
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
