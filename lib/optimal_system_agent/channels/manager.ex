defmodule OptimalSystemAgent.Channels.Manager do
  @moduledoc """
  Manages the lifecycle of all channel adapters.

  Responsible for:
  - Starting configured channel adapters on application boot
  - Routing outbound messages to the correct adapter
  - Reporting which channels are currently active

  ## Usage

      # Start all channels that have config present (called from Application or IEx)
      OptimalSystemAgent.Channels.Manager.start_configured_channels()

      # List active channels
      OptimalSystemAgent.Channels.Manager.list_channels()
      #=> [%{name: :telegram, connected: true, module: OptimalSystemAgent.Channels.Telegram}, ...]

      # Send a message via a specific channel
      OptimalSystemAgent.Channels.Manager.send_to_channel(:telegram, "123456789", "Hello!")

  ## Channel registration
  All adapters are registered in `@channel_modules` below. Add new adapters there.
  """
  require Logger

  @channel_modules [
    OptimalSystemAgent.Channels.Telegram,
    OptimalSystemAgent.Channels.Discord,
    OptimalSystemAgent.Channels.Slack,
    OptimalSystemAgent.Channels.WhatsApp,
    OptimalSystemAgent.Channels.Signal,
    OptimalSystemAgent.Channels.Matrix,
    OptimalSystemAgent.Channels.Email,
    OptimalSystemAgent.Channels.QQ,
    OptimalSystemAgent.Channels.DingTalk,
    OptimalSystemAgent.Channels.Feishu
  ]

  @doc """
  Start all channel adapters that have their required configuration present.

  Each adapter's `init/1` returns `:ignore` when its token/config is absent,
  so it's safe to attempt starting all of them — only configured ones will run.

  Returns a list of `{module, result}` tuples.
  """
  def start_configured_channels do
    Logger.info("Channels.Manager: Starting configured channel adapters...")

    results =
      Enum.map(@channel_modules, fn module ->
        result =
          case DynamicSupervisor.start_child(
                 OptimalSystemAgent.Channels.Supervisor,
                 {module, []}
               ) do
            {:ok, pid} ->
              Logger.info("Channels.Manager: Started #{inspect(module)} (pid=#{inspect(pid)})")
              {:ok, pid}

            {:error, {:already_started, pid}} ->
              {:ok, pid}

            :ignore ->
              # Adapter returned :ignore — not configured, skip silently
              :ignore

            {:error, reason} ->
              Logger.warning("Channels.Manager: Failed to start #{inspect(module)}: #{inspect(reason)}")
              {:error, reason}
          end

        {module, result}
      end)

    active_count =
      Enum.count(results, fn
        {_, {:ok, _}} -> true
        _ -> false
      end)

    Logger.info("Channels.Manager: #{active_count}/#{length(@channel_modules)} channel adapters started")
    results
  end

  @doc """
  List all registered channel adapters with their current status.

  Returns a list of maps:
      [
        %{name: :telegram, module: ..., connected: true, pid: #PID<...>},
        %{name: :slack, module: ..., connected: false, pid: nil},
        ...
      ]
  """
  def list_channels do
    Enum.map(@channel_modules, fn module ->
      pid = Process.whereis(module)
      connected = pid_connected?(module, pid)

      %{
        name: safe_channel_name(module),
        module: module,
        connected: connected,
        pid: pid
      }
    end)
  end

  @doc """
  List only the channels that are currently connected/active.
  """
  def active_channels do
    list_channels()
    |> Enum.filter(& &1.connected)
  end

  @doc """
  Send a message via a specific channel adapter.

  `channel` is the channel atom (`:telegram`, `:slack`, etc.) or module name.
  `chat_id` is the platform-specific destination ID.
  `message` is the text to send.

  Returns `:ok` or `{:error, reason}`.
  """
  def send_to_channel(channel, chat_id, message, opts \\ []) do
    case find_module(channel) do
      nil ->
        Logger.warning("Channels.Manager: Unknown channel #{inspect(channel)}")
        {:error, :unknown_channel}

      module ->
        case Process.whereis(module) do
          nil ->
            {:error, :channel_not_started}

          _pid ->
            try do
              module.send_message(chat_id, message, opts)
            rescue
              e ->
                Logger.warning("Channels.Manager: send_to_channel error for #{channel}: #{inspect(e)}")
                {:error, e}
            end
        end
    end
  end

  @doc """
  Check whether a given channel is currently active.
  """
  def channel_active?(channel) do
    case find_module(channel) do
      nil -> false
      module -> pid_connected?(module, Process.whereis(module))
    end
  end

  @doc """
  Return the list of all known channel module atoms (including unstarted ones).
  """
  def known_channels do
    Enum.map(@channel_modules, &safe_channel_name/1)
  end

  # ── Private Helpers ──────────────────────────────────────────────────

  defp find_module(channel) when is_atom(channel) do
    Enum.find(@channel_modules, fn mod ->
      safe_channel_name(mod) == channel or mod == channel
    end)
  end

  defp find_module(_), do: nil

  defp safe_channel_name(module) do
    try do
      module.channel_name()
    rescue
      _ -> module
    end
  end

  defp pid_connected?(module, pid) when is_pid(pid) do
    try do
      module.connected?()
    rescue
      _ -> Process.alive?(pid)
    end
  end

  defp pid_connected?(_module, nil), do: false
end
