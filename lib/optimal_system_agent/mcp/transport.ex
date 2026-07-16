defmodule OptimalSystemAgent.MCP.Transport do
  @moduledoc """
  Behaviour for MCP transports (the byte-pipe under the JSON-RPC layer).

  A transport owns a connection to one MCP server and delivers inbound,
  newline-framed JSON messages to its owner process as Erlang messages:

    * `{:mcp_message, ref, binary}` — one complete inbound JSON message
    * `{:mcp_closed, ref, reason}`  — the connection closed / failed

  `ref` is an opaque term chosen by the owner at `start_link/1` time (via the
  `:ref` option) so a single owner can multiplex several transports.

  Implementations: `OptimalSystemAgent.MCP.Transport.Stdio`. An HTTP/SSE
  transport is a Phase 2 addition that will implement this same contract.
  """

  @typedoc "Opaque owner-chosen correlation reference."
  @type ref :: term()

  @doc """
  Start the transport process.

  Required options:
    * `:owner` — pid that receives `{:mcp_message, ref, _}` / `{:mcp_closed, ref, _}`
    * `:ref`   — correlation term echoed back in every delivered message

  Transport-specific options (e.g. `:command`, `:args`, `:env` for stdio)
  are passed through in the same keyword list.
  """
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}

  @doc "Send one JSON message (already-encoded binary) to the server."
  @callback send_message(transport :: pid(), message :: binary()) :: :ok | {:error, term()}
end
