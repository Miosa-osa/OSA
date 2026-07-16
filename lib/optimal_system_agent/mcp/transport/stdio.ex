defmodule OptimalSystemAgent.MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport for a local MCP server subprocess.

  Wraps an Erlang `Port` opened with `{:spawn_executable, exe}` in `:binary`
  mode with `:exit_status`. MCP frames messages as newline-delimited JSON, so
  we buffer partial lines and emit one `{:mcp_message, ref, line}` per
  complete line. The child's stderr is captured via `:stderr_to_stdout`... no —
  stderr must stay separate from the JSON channel, so we do NOT merge it;
  instead we rely on the child writing protocol JSON to stdout and diagnostics
  to its own stderr, and surface any stdout non-JSON lines to `Logger`.

  On owner death or port exit the port is closed and `{:mcp_closed, ref, _}`
  is delivered. The GenServer traps exits so it can `Port.close/1` cleanly.

  Implements `OptimalSystemAgent.MCP.Transport`.
  """

  @behaviour OptimalSystemAgent.MCP.Transport

  use GenServer
  require Logger

  defstruct [:port, :owner, :ref, :name, buffer: "", exe: nil]

  # ── Transport API ─────────────────────────────────────────────────────

  @impl OptimalSystemAgent.MCP.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl OptimalSystemAgent.MCP.Transport
  def send_message(transport, message) when is_binary(message) do
    GenServer.call(transport, {:send, message})
  catch
    :exit, reason -> {:error, {:transport_down, reason}}
  end

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.fetch!(opts, :owner)
    ref = Keyword.fetch!(opts, :ref)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})
    name = Keyword.get(opts, :name, command)

    case resolve_executable(command) do
      {:ok, exe} ->
        port_env =
          Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

        port =
          Port.open(
            {:spawn_executable, exe},
            [
              :binary,
              :exit_status,
              :hide,
              {:args, args},
              {:env, port_env}
            ]
          )

        {:ok, %__MODULE__{port: port, owner: owner, ref: ref, name: name, exe: exe}}

      {:error, reason} ->
        {:stop, {:executable_not_found, command, reason}}
    end
  end

  @impl GenServer
  def handle_call({:send, message}, _from, %{port: port} = state) when is_port(port) do
    try do
      Port.command(port, [message, "\n"])
      {:reply, :ok, state}
    rescue
      e -> {:reply, {:error, Exception.message(e)}, state}
    catch
      :error, reason -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send, _message}, _from, state) do
    {:reply, {:error, :no_port}, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> data)
    Enum.each(lines, &deliver_line(&1, state))
    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    notify_closed(state, {:exit_status, status})
    {:stop, :normal, %{state | port: nil}}
  end

  # Owner or a linked process died — shut down and close the port.
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private ───────────────────────────────────────────────────────────

  # Deliver a complete inbound line. Blank lines are ignored; non-JSON lines
  # (which some servers emit as diagnostics on stdout) are logged, not sent.
  defp deliver_line("", _state), do: :ok

  defp deliver_line(line, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :ok

      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        send(state.owner, {:mcp_message, state.ref, trimmed})

      true ->
        Logger.debug("[MCP.Stdio:#{state.name}] non-JSON stdout: #{trimmed}")
    end
  end

  defp notify_closed(%{owner: owner, ref: ref}, reason) do
    send(owner, {:mcp_closed, ref, reason})
  end

  # Split accumulated data on newlines; return {complete_lines, remainder}.
  defp split_lines(data) do
    parts = String.split(data, "\n")

    case Enum.reverse(parts) do
      [last | rev_complete] -> {Enum.reverse(rev_complete), last}
      [] -> {[], ""}
    end
  end

  # Resolve a command to an absolute executable path. Absolute/relative paths
  # with a slash are used as-is; bare names are looked up on PATH.
  defp resolve_executable(command) do
    cond do
      String.contains?(command, "/") ->
        if File.exists?(command), do: {:ok, command}, else: {:error, :enoent}

      true ->
        case System.find_executable(command) do
          nil -> {:error, :not_on_path}
          path -> {:ok, path}
        end
    end
  end
end
