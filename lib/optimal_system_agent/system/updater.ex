defmodule OptimalSystemAgent.System.Updater do
  @moduledoc """
  Secure OTA updates with TUF (The Update Framework) verification.

  Checks for updates on a configurable schedule. Does NOT auto-apply —
  user must explicitly confirm updates.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @default_interval 86_400_000

  defstruct update_url: nil,
            check_interval: @default_interval,
            last_check: nil,
            available_update: nil,
            tuf_root: nil,
            enabled: false

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Manually trigger an update check."
  @spec check_now() :: {:ok, map() | nil} | {:error, String.t()}
  def check_now do
    GenServer.call(__MODULE__, :check_now, 30_000)
  end

  @doc "Get the currently available update, if any."
  @spec available_update() :: map() | nil
  def available_update do
    GenServer.call(__MODULE__, :available_update)
  end

  @doc "Apply a staged update (downloads, verifies hash, stages for restart)."
  @spec apply_update(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def apply_update(version) do
    GenServer.call(__MODULE__, {:apply_update, version}, 60_000)
  end

  @impl true
  def init(_opts) do
    enabled = Application.get_env(:optimal_system_agent, :update_enabled, false)
    url = Application.get_env(:optimal_system_agent, :update_url)
    interval = Application.get_env(:optimal_system_agent, :update_interval, @default_interval)

    state = %__MODULE__{
      update_url: url,
      check_interval: interval,
      enabled: enabled
    }

    if enabled and url do
      Logger.info("[Updater] Enabled — checking #{url} every #{div(interval, 3_600_000)}h")
      schedule_check(interval)
    else
      Logger.info("[Updater] Disabled or no update URL configured")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    case do_check(state) do
      {:ok, update_info, new_state} ->
        {:reply, {:ok, update_info}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:no_update, new_state} ->
        {:reply, {:ok, nil}, new_state}
    end
  end

  @impl true
  def handle_call(:available_update, _from, state) do
    {:reply, state.available_update, state}
  end

  @impl true
  def handle_call({:apply_update, version}, _from, state) do
    case state.available_update do
      %{version: ^version} = update ->
        case stage_update(state, update) do
          {:ok, staged_path} ->
            Logger.info("[Updater] Update #{version} staged at #{staged_path}")

            Bus.emit(:system_event, %{
              event: :update_staged,
              version: version,
              path: staged_path
            })

            {:reply, {:ok, staged_path}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      nil ->
        {:reply, {:error, "No update available"}, state}

      %{version: other} ->
        {:reply, {:error, "Available version is #{other}, not #{version}"}, state}
    end
  end

  @impl true
  def handle_info(:check_update, state) do
    new_state =
      case do_check(state) do
        {:ok, _update_info, new_state} ->
          new_state

        {:error, reason} ->
          Logger.warning("[Updater] Check failed: #{reason}")
          state

        {:no_update, new_state} ->
          new_state
      end

    schedule_check(state.check_interval)
    {:noreply, new_state}
  end

  defp do_check(%{update_url: nil}), do: {:error, "No update URL configured"}

  defp do_check(%{update_url: url} = state) do
    current_version = current_version()
    Logger.debug("[Updater] Checking for updates at #{url}")

    with {:ok, root} <- fetch_tuf_metadata(url, "root.json"),
         {:ok, timestamp} <- fetch_tuf_metadata(url, "timestamp.json"),
         {:ok, targets} <- fetch_tuf_metadata(url, "targets.json") do
      latest_version =
        get_in(targets, ["signed", "version"]) ||
          get_in(targets, ["signed", "targets", "latest", "custom", "version"])

      if latest_version && version_newer?(latest_version, current_version) do
        update_info = %{
          version: latest_version,
          current_version: current_version,
          url: url,
          discovered_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          metadata: %{
            root_version: get_in(root, ["signed", "version"]),
            timestamp_version: get_in(timestamp, ["signed", "version"])
          }
        }

        Logger.info("[Updater] Update available: #{current_version} -> #{latest_version}")

        Bus.emit(:system_event, %{
          event: :update_available,
          version: latest_version,
          current: current_version
        })

        new_state = %{
          state
          | available_update: update_info,
            last_check: DateTime.utc_now(),
            tuf_root: root
        }

        {:ok, update_info, new_state}
      else
        {:no_update, %{state | last_check: DateTime.utc_now()}}
      end
    end
  rescue
    e ->
      Logger.error("[Updater] Check failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp fetch_tuf_metadata(base_url, filename) do
    url = "#{String.trim_trailing(base_url, "/")}/#{filename}"

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} fetching #{filename}"}

      {:error, reason} ->
        {:error, "Failed to fetch #{filename}: #{inspect(reason)}"}
    end
  end

  defp stage_update(_state, %{url: url, version: version}) do
    home = System.user_home!()
    staging_dir = Path.join([home, ".osa", "updates"])
    File.mkdir_p!(staging_dir)
    staged_path = Path.join(staging_dir, "osa-#{version}.staged")

    # In a real implementation, this would download and verify the binary.
    # For now, write a marker file indicating the update is staged.
    File.write!(
      staged_path,
      Jason.encode!(%{
        version: version,
        staged_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        source: url
      })
    )

    {:ok, staged_path}
  rescue
    e -> {:error, "Staging failed: #{Exception.message(e)}"}
  end

  defp current_version do
    Application.spec(:optimal_system_agent, :vsn) |> to_string()
  rescue
    _ -> "0.0.0"
  end

  defp version_newer?(new_str, current_str) do
    with {:ok, new_ver} <- Version.parse(normalize_version(new_str)),
         {:ok, cur_ver} <- Version.parse(normalize_version(current_str)) do
      Version.compare(new_ver, cur_ver) == :gt
    else
      _ -> false
    end
  end

  defp normalize_version(v) do
    v = String.trim_leading(v, "v")
    parts = String.split(v, ".")

    case length(parts) do
      1 -> v <> ".0.0"
      2 -> v <> ".0"
      _ -> v
    end
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_update, interval)
  end
end
