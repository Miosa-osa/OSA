defmodule OptimalSystemAgent.System.UpdateChecker do
  @moduledoc """
  Cached "update available" signal for the `GET /health` path.

  The TUI reads `GET /health` on startup and refresh; this module lets that
  response carry an `update` object without doing any network or git work on the
  hot path. A lightweight poller (this GenServer) refreshes a CACHED result into
  application env; `health_update/0` only reads that cache — it never fetches.

  The comparison itself reuses the update checkers OSA already has, in order:

    1. `System.Updater.available_update/0` — the opt-in TUF OTA poller's cached
       result (the only path that discovers a genuinely newer remote build).
    2. `Onboarding.update_check/0` — the local (git tags + bundled changelog,
       no network) "CC parity AutoUpdater status line". Never auto-installs.

  Neither is invoked on the /health path; both run in this GenServer's timer.

  ## Gating (mirrors Codex `is_source_build`)

  A source/dev checkout, or an explicit disable, pins `available: false` so a
  developer running from source is never nagged. A failed or absent check also
  defaults to `available: false` — it must never break /health.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Onboarding

  @cache_key :update_status
  # Poll daily. Matches the OTA updater's default cadence — this is only a cheap
  # local recompute of the cached signal, not a network install.
  @refresh_interval 86_400_000
  # Fire the first refresh a few seconds after boot so the first /health after a
  # cold start can report, without competing with boot-critical work.
  @boot_delay 5_000

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Cheap, non-blocking read of the cached update signal for the /health body.

  Reads application env only — no GenServer call, no git, no network — so it is
  safe on every health request and total (never raises). Absent cache (checker
  hasn't run, or was disabled) reports `available: false`.
  """
  @spec health_update() :: %{
          available: boolean(),
          current_version: String.t(),
          latest_version: String.t() | nil
        }
  def health_update do
    case Application.get_env(:optimal_system_agent, @cache_key) do
      %{available: available, current_version: current} = cached ->
        %{
          available: available == true,
          current_version: to_string(current),
          latest_version: normalize_latest(Map.get(cached, :latest_version))
        }

      _ ->
        %{available: false, current_version: current_version(), latest_version: nil}
    end
  end

  @doc """
  Recompute the cached signal now (gated + guarded) and store it in app env.

  Returns the cache map. Called by this GenServer's boot/interval timer; exposed
  so a test can drive a deterministic refresh without the timer.
  """
  @spec refresh() :: %{
          available: boolean(),
          current_version: String.t(),
          latest_version: String.t() | nil
        }
  def refresh do
    result = compute()
    Application.put_env(:optimal_system_agent, @cache_key, result)
    result
  end

  @doc """
  True for a source/dev checkout (no packaged release), so update notices are
  suppressed — the local git/changelog compare is meaningless for a developer
  running from source. Mirrors Codex `is_source_build`.

  A packaged release stamps `OSA_VERSION`; absent that, a running Mix (dev, test,
  source checkout) is treated as a source build.
  """
  @spec source_build?() :: boolean()
  def source_build? do
    if env_present?("OSA_VERSION"), do: false, else: mix_available?()
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.send_after(self(), :refresh, @boot_delay)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    safe_refresh()
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, state}
  end

  # ── Compute ──────────────────────────────────────────────────────────

  defp compute do
    current = current_version()

    cond do
      not enabled?() ->
        none(current)

      source_build?() ->
        none(current)

      true ->
        case updater_cached() do
          %{available: true} = up -> up
          _ -> from_onboarding(current)
        end
    end
  rescue
    _ -> none(current_version())
  catch
    _, _ -> none(current_version())
  end

  # Cached result from the opt-in TUF OTA updater (network-discovered). A
  # GenServer.call is fine here — compute/0 runs in this poller, never on the
  # /health path. Absent process or no update -> nil (fall through to local).
  defp updater_cached do
    if Process.whereis(OptimalSystemAgent.System.Updater) do
      case OptimalSystemAgent.System.Updater.available_update() do
        %{version: latest} = up ->
          current = Map.get(up, :current_version) || current_version()
          %{available: true, current_version: to_string(current), latest_version: to_string(latest)}

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Local (no network) compare via the existing CC-parity status line.
  defp from_onboarding(current) do
    case Onboarding.update_check() do
      %{update_available: true, latest: latest} = st ->
        cur = Map.get(st, :current) || current

        %{
          available: true,
          current_version: to_string(cur),
          latest_version: to_string(latest)
        }

      %{current: cur} ->
        none(to_string(cur))

      _ ->
        none(current)
    end
  rescue
    _ -> none(current)
  end

  defp none(current), do: %{available: false, current_version: to_string(current), latest_version: nil}

  defp enabled? do
    Application.get_env(:optimal_system_agent, :update_check_enabled, true)
  end

  defp safe_refresh do
    refresh()
  rescue
    e -> Logger.debug("[UpdateChecker] refresh failed: #{inspect(e)}")
  catch
    _, _ -> :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp current_version do
    OptimalSystemAgent.ReleaseNotes.current_version()
  rescue
    _ -> "unknown"
  end

  defp normalize_latest(v) when is_binary(v) and v != "", do: v
  defp normalize_latest(_), do: nil

  defp env_present?(key) do
    case System.get_env(key) do
      v when is_binary(v) and v != "" -> true
      _ -> false
    end
  end

  defp mix_available? do
    Code.ensure_loaded?(Mix)
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
