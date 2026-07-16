defmodule OptimalSystemAgent.MCP.Server.StdioServer do
  @moduledoc """
  MCP *server* over stdio: exposes OSA as an MCP server to any MCP client
  (e.g. Claude Desktop) via newline-delimited JSON-RPC on stdin/stdout.

  CRITICAL: stdout is the JSON-RPC channel. Nothing else may be written to
  stdout — all logging must go to stderr (configured by `mix osa.mcp`). This
  module writes ONLY encoded JSON-RPC responses to stdout, each followed by a
  newline.

  Reads are line-based via `IO.read(:stdio, :line)` in a dedicated reader
  process so the owning GenServer stays responsive. Each complete line is
  decoded, routed through `Server.Dispatcher`, and any reply is written back.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.MCP.Protocol.JSONRPC
  alias OptimalSystemAgent.MCP.Server.Dispatcher

  defstruct [:io, :reader]

  @doc "Start the stdio server. `:io` defaults to `:stdio`."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    io = Keyword.get(opts, :io, :stdio)
    parent = self()
    reader = spawn_link(fn -> read_loop(parent, io) end)
    {:ok, %__MODULE__{io: io, reader: reader}}
  end

  @impl true
  def handle_cast({:line, line}, state) do
    process_line(line, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:eof, state) do
    Logger.info("[MCP.Server] stdin closed (EOF); shutting down stdio server")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Line processing ───────────────────────────────────────────────────

  @doc false
  def process_line(line, state) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :ok
    else
      case JSONRPC.decode(trimmed) do
        {:ok, message} ->
          case Dispatcher.dispatch(message) do
            {:reply, response} -> write(state.io, response)
            :noreply -> :ok
          end

        {:error, reason} ->
          Logger.warning("[MCP.Server] failed to decode inbound line: #{inspect(reason)}")
          # Per JSON-RPC, a parse error gets a null-id error response.
          write(state.io, JSONRPC.error_response(nil, -32700, "Parse error"))
      end
    end
  rescue
    e ->
      Logger.error("[MCP.Server] dispatch crashed: #{Exception.message(e)}")
      :ok
  end

  # Write a JSON-RPC response to stdout, newline-framed. stdout ONLY.
  defp write(io, response) do
    case JSONRPC.encode(response) do
      {:ok, json} -> IO.binwrite(io, [json, "\n"])
      {:error, reason} -> Logger.error("[MCP.Server] encode failed: #{inspect(reason)}")
    end
  end

  # ── Reader process ────────────────────────────────────────────────────

  defp read_loop(parent, io) do
    case IO.read(io, :line) do
      :eof ->
        send(parent, :eof)

      {:error, reason} ->
        Logger.error("[MCP.Server] stdin read error: #{inspect(reason)}")
        send(parent, :eof)

      data when is_binary(data) ->
        GenServer.cast(parent, {:line, data})
        read_loop(parent, io)
    end
  end
end
