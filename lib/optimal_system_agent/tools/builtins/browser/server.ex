defmodule OptimalSystemAgent.Tools.Builtins.Browser.Server do
  @moduledoc """
  GenServer managing a persistent headless browser process via Port.

  Communicates with `priv/browser/browser_server.js` (Playwright) using
  newline-delimited JSON over stdin/stdout.

  Starts lazily on first browser tool call and auto-closes after 5 minutes
  of inactivity.
  """

  use GenServer
  require Logger

  @idle_timeout_ms 5 * 60 * 1_000
  @command_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a JSON command to the browser process. Returns `{:ok, result}` or `{:error, reason}`."
  def send_command(command) when is_map(command) do
    GenServer.call(__MODULE__, {:command, command}, @command_timeout_ms + 5_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  defstruct [:port, :buffer, :pending, :idle_ref]

  @impl true
  def init(_opts) do
    case open_port() do
      {:ok, port} ->
        ref = schedule_idle_shutdown()
        {:ok, %__MODULE__{port: port, buffer: "", pending: nil, idle_ref: ref}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:command, command}, from, %{port: port} = state) when not is_nil(port) do
    json = Jason.encode!(command) <> "\n"
    Port.command(port, json)
    state = cancel_idle(state)
    {:noreply, %{state | pending: from}}
  end

  def handle_call({:command, _command}, _from, %{port: nil} = state) do
    {:reply, {:error, "Browser process not running"}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> to_string(data)

    case String.split(buffer, "\n", parts: 2) do
      [complete, rest] ->
        state = %{state | buffer: rest}
        state = handle_response(complete, state)
        {:noreply, state}

      [_incomplete] ->
        {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[BrowserServer] Port exited with status #{status}")

    if state.pending do
      GenServer.reply(state.pending, {:error, "Browser process exited (status #{status})"})
    end

    {:stop, :normal, %{state | port: nil, pending: nil}}
  end

  def handle_info(:idle_shutdown, state) do
    Logger.info("[BrowserServer] Idle timeout — shutting down browser")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = _state) when not is_nil(port) do
    # Try graceful close
    try do
      json = Jason.encode!(%{"action" => "close"}) <> "\n"
      Port.command(port, json)
      # Give it a moment to close
      Process.sleep(200)
    rescue
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp open_port do
    script_path = browser_script_path()

    if File.exists?(script_path) do
      node = System.find_executable("node")

      if node do
        port =
          Port.open(
            {:spawn_executable, node},
            [
              :binary,
              :exit_status,
              :use_stdio,
              {:args, [script_path]},
              {:cd, Path.dirname(script_path)}
            ]
          )

        {:ok, port}
      else
        {:error, "node executable not found"}
      end
    else
      {:error, "Browser script not found at #{script_path}"}
    end
  rescue
    e -> {:error, "Failed to open browser port: #{inspect(e)}"}
  end

  defp browser_script_path do
    case :code.priv_dir(:optimal_system_agent) do
      {:error, _} ->
        Path.join([File.cwd!(), "priv", "browser", "browser_server.js"])

      priv_dir ->
        Path.join([to_string(priv_dir), "browser", "browser_server.js"])
    end
  end

  defp handle_response(json_str, state) do
    case Jason.decode(json_str) do
      {:ok, %{"ok" => true, "result" => result}} ->
        if state.pending, do: GenServer.reply(state.pending, {:ok, to_string(result)})
        ref = schedule_idle_shutdown()
        %{state | pending: nil, idle_ref: ref}

      {:ok, %{"ok" => false, "error" => error}} ->
        if state.pending, do: GenServer.reply(state.pending, {:error, error})
        ref = schedule_idle_shutdown()
        %{state | pending: nil, idle_ref: ref}

      {:error, _decode_error} ->
        Logger.warning("[BrowserServer] Invalid JSON from port: #{json_str}")

        if state.pending,
          do: GenServer.reply(state.pending, {:error, "Invalid response from browser"})

        ref = schedule_idle_shutdown()
        %{state | pending: nil, idle_ref: ref}
    end
  end

  defp schedule_idle_shutdown do
    Process.send_after(self(), :idle_shutdown, @idle_timeout_ms)
  end

  defp cancel_idle(%{idle_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | idle_ref: nil}
  end

  defp cancel_idle(state), do: state
end
