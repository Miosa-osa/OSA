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

  alias OptimalSystemAgent.Events.Bus

  @osa_dir Path.expand("~/.osa")

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
              Logger.warning(
                "Channels.Manager: Failed to start #{inspect(module)}: #{inspect(reason)}"
              )

              {:error, reason}
          end

        {module, result}
      end)

    active_count =
      Enum.count(results, fn
        {_, {:ok, _}} -> true
        _ -> false
      end)

    Logger.info(
      "Channels.Manager: #{active_count}/#{length(@channel_modules)} channel adapters started"
    )

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
                Logger.warning(
                  "Channels.Manager: send_to_channel error for #{channel}: #{inspect(e)}"
                )

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

  @doc """
  Start a specific channel adapter by name.
  Returns `{:ok, pid}`, `{:error, :not_configured}`, or `{:error, reason}`.
  """
  def start_channel(channel) when is_atom(channel) do
    case find_module(channel) do
      nil ->
        {:error, :unknown_channel}

      module ->
        case DynamicSupervisor.start_child(
               OptimalSystemAgent.Channels.Supervisor,
               {module, []}
             ) do
          {:ok, pid} ->
            Logger.info("Channels.Manager: Started #{channel} (pid=#{inspect(pid)})")
            Bus.emit(:channel_connected, %{channel: channel, pid: pid})
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          :ignore ->
            {:error, :not_configured}

          {:error, reason} ->
            Bus.emit(:channel_error, %{channel: channel, error: reason})
            {:error, reason}
        end
    end
  end

  @doc """
  Stop a specific channel adapter by name.
  Returns `:ok` or `{:error, reason}`.
  """
  def stop_channel(channel) when is_atom(channel) do
    case find_module(channel) do
      nil ->
        {:error, :unknown_channel}

      module ->
        case Process.whereis(module) do
          nil ->
            {:error, :not_running}

          pid ->
            case DynamicSupervisor.terminate_child(
                   OptimalSystemAgent.Channels.Supervisor,
                   pid
                 ) do
              :ok ->
                Logger.info("Channels.Manager: Stopped #{channel}")
                Bus.emit(:channel_disconnected, %{channel: channel})
                :ok

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  @doc """
  Get detailed status for a specific channel.
  Returns a map with name, module, pid, connected, and configured flags.
  """
  def channel_status(channel) when is_atom(channel) do
    case find_module(channel) do
      nil ->
        {:error, :unknown_channel}

      module ->
        pid = Process.whereis(module)
        connected = pid_connected?(module, pid)
        configured = channel_configured?(channel)

        {:ok,
         %{
           name: channel,
           module: module,
           pid: pid,
           connected: connected,
           configured: configured
         }}
    end
  end

  @doc """
  Test that a channel adapter is alive and responding.
  Returns `{:ok, :connected}` or `{:error, reason}`.
  """
  def test_channel(channel) when is_atom(channel) do
    case find_module(channel) do
      nil ->
        {:error, :unknown_channel}

      module ->
        pid = Process.whereis(module)

        cond do
          is_nil(pid) -> {:error, :not_running}
          not Process.alive?(pid) -> {:error, :process_dead}
          pid_connected?(module, pid) -> {:ok, :connected}
          true -> {:error, :not_connected}
        end
    end
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

  defp channel_configured?(channel) do
    config_path = Path.join(@osa_dir, "config.json")

    if File.exists?(config_path) do
      with {:ok, contents} <- File.read(config_path),
           {:ok, config} <- Jason.decode(contents) do
        channels = Map.get(config, "channels", %{})
        Map.has_key?(channels, to_string(channel))
      else
        _ -> false
      end
    else
      # Fall back to checking Application env for known config keys
      case channel do
        :telegram -> Application.get_env(:optimal_system_agent, :telegram_token) != nil
        :discord -> Application.get_env(:optimal_system_agent, :discord_token) != nil
        :slack -> Application.get_env(:optimal_system_agent, :slack_bot_token) != nil
        :whatsapp -> Application.get_env(:optimal_system_agent, :whatsapp_token) != nil
        :signal -> Application.get_env(:optimal_system_agent, :signal_phone) != nil
        :matrix -> Application.get_env(:optimal_system_agent, :matrix_homeserver) != nil
        :email -> Application.get_env(:optimal_system_agent, :email_smtp_host) != nil
        :qq -> Application.get_env(:optimal_system_agent, :qq_appid) != nil
        :dingtalk -> Application.get_env(:optimal_system_agent, :dingtalk_app_key) != nil
        :feishu -> Application.get_env(:optimal_system_agent, :feishu_app_id) != nil
        _ -> false
      end
    end
  end
end
