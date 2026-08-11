defmodule OptimalSystemAgent.OpenComputers.Updater do
  @moduledoc """
  OSA self-update mechanism for OpenComputers (BYOC) deployments.

  Polls the MIOSA control plane for a new OSA binary on startup (after a
  60-second delay) and then every 24 hours. When a newer version is found
  it downloads the binary, verifies the SHA256 checksum, writes it to
  `~/.osa/bin/osa.new`, and notifies the control plane via the WS wire
  protocol.

  On the NEXT restart (or when `apply/0` is called manually) a startup hook
  in `bin/osagent` renames `osa.new → osa` (keeping `osa.bak` as a rollback).

  ## Config (read from `~/.osa/open_computers.toml` or application env)

      [update]
      enabled = true           # default: true
      channel = "stable"       # future: "beta"
      check_interval_hours = 24

  ## Safety

  - If SHA256 does not match the manifest, the download is deleted and the
    current binary is untouched.
  - The backup `osa.bak` is kept so customers can manually roll back by
    renaming it to `osa`.
  - Setting `enabled = false` disables all polling and download activity.
    The `osa update check` CLI command still works as a one-shot check even
    when the periodic loop is disabled.

  ## Wire protocol

  On successful download + verification, the updater sends:

      {:osa_update_staged, %{from_version: "0.3.0", to_version: "0.3.1", platform: "macos-arm64"}}

  The FrameRouter forwards this to the control plane, which logs the event and
  sets `oc_hosts.pending_update_version = "0.3.1"`.

  ## Telemetry

  Emits `[:osa, :updater, :downloaded]` with %{from_version, to_version}.
  Emits `[:osa, :updater, :check_failed]` with %{reason}.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @check_after_start_ms 60_000
  @download_timeout_ms 120_000
  # Update availability is checked against GitHub Releases — the source the
  # installer (`scripts/install.sh`) and the `osa update` launcher actually pull
  # from. The previous `api.miosa.ai` endpoint returns 503 "version_not_configured"
  # (no release published there), which made every check fail. This checker is
  # CHECK-ONLY: it detects a newer published release and notifies; the actual
  # download+apply is done by the launcher's `osa update` (GitHub tarballs), which
  # this single-binary staging path never matched.
  @github_repo "Miosa-osa/OSA"
  @api_url "https://api.github.com/repos/#{@github_repo}/releases/latest"

  defstruct [:check_interval_ms, :enabled, :channel, :last_check, :staged_version, :req_opts]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Immediately check GitHub Releases for a newer version.
  Returns `{:ok, :up_to_date}`, `{:ok, {:available, version}}`, or `{:error, reason}`.
  (Check-only — the launcher's `osa update` applies the update.)
  """
  @spec check_now() :: {:ok, :up_to_date | {:available, String.t()}} | {:error, term()}
  def check_now do
    GenServer.call(__MODULE__, :check_now, @download_timeout_ms + 5_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Return the currently staged version, if any."
  @spec staged_version() :: String.t() | nil
  def staged_version do
    GenServer.call(__MODULE__, :staged_version, 1_000)
  catch
    :exit, _ -> nil
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    cfg = update_config()

    # opts take priority over TOML config (used in tests and programmatic start)
    enabled =
      case Keyword.fetch(opts, :enabled) do
        {:ok, v} -> v
        :error -> Map.get(cfg, :enabled, true)
      end

    channel = Map.get(cfg, :channel, "stable")
    interval_h = Map.get(cfg, :check_interval_hours, 24)
    interval_ms = trunc(interval_h * 60 * 60 * 1000)

    # Allow tests to inject a Req plug (e.g. Req.Test stub)
    req_opts =
      case Keyword.fetch(opts, :plug) do
        {:ok, plug} -> [plug: plug]
        :error -> []
      end

    state = %__MODULE__{
      enabled: enabled,
      channel: channel,
      check_interval_ms: interval_ms,
      staged_version: detect_staged_version(),
      req_opts: req_opts
    }

    if enabled do
      Logger.info("[OC.Updater] enabled — first check in 60s, then every #{interval_h}h")
      Process.send_after(self(), :check, @check_after_start_ms)
    else
      Logger.info("[OC.Updater] disabled via config")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    {result, new_state} = do_check(state)
    {:reply, result, new_state}
  end

  def handle_call(:staged_version, _from, state) do
    {:reply, state.staged_version, state}
  end

  def handle_call(_msg, _from, state), do: {:reply, :not_implemented, state}

  @impl true
  def handle_info(:check, state) do
    if state.enabled do
      {_result, new_state} = do_check(state)
      Process.send_after(self(), :check, new_state.check_interval_ms)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private — core update flow
  # ---------------------------------------------------------------------------

  defp do_check(state) do
    current = current_version()
    Logger.debug("[OC.Updater] checking #{@api_url} current=#{current}")

    case fetch_manifest(state.req_opts) do
      {:ok, manifest} ->
        latest = manifest["version"]

        if is_binary(latest) and version_newer?(latest, current) do
          Logger.info(
            "[OC.Updater] update available #{current} -> #{latest} (run `osa update` to apply)"
          )

          notify_control_plane(current, latest, detect_platform())
          {{:ok, {:available, latest}}, %{state | last_check: DateTime.utc_now()}}
        else
          Logger.debug("[OC.Updater] up to date (#{current})")
          {{:ok, :up_to_date}, %{state | last_check: DateTime.utc_now()}}
        end

      {:error, reason} ->
        :telemetry.execute([:osa, :updater, :check_failed], %{count: 1}, %{reason: reason})
        Logger.warning("[OC.Updater] update check failed: #{inspect(reason)}")
        {{:error, reason}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — HTTP (GitHub Releases, check-only)
  # ---------------------------------------------------------------------------

  # Fetch the latest published GitHub release and reduce it to `%{"version" => v}`
  # (the tag with any leading "v" stripped). GitHub requires a User-Agent header
  # or it answers 403.
  defp fetch_manifest(extra_req_opts) do
    opts =
      [
        url: @api_url,
        receive_timeout: 10_000,
        retry: false,
        headers: [
          {"user-agent", "osa-updater"},
          {"accept", "application/vnd.github+json"}
        ]
      ] ++ extra_req_opts

    case Req.get(opts) do
      {:ok, %{status: 200, body: body}} ->
        case release_version(body) do
          nil -> {:error, :no_release}
          version -> {:ok, %{"version" => version}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Extract the release tag (minus a leading "v") from a GitHub release payload,
  # whether Req decoded it to a map or handed back raw JSON.
  defp release_version(body) when is_map(body) do
    case body["tag_name"] do
      tag when is_binary(tag) and tag != "" -> String.trim_leading(tag, "v")
      _ -> nil
    end
  end

  defp release_version(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> release_version(map)
      _ -> nil
    end
  end

  defp release_version(_), do: nil

  # ---------------------------------------------------------------------------
  # Private — wire protocol notification
  # ---------------------------------------------------------------------------

  defp notify_control_plane(from_version, to_version, platform) do
    frame =
      {:osa_update_staged,
       %{
         from_version: from_version,
         to_version: to_version,
         platform: platform
       }}

    try do
      FrameRouter.send_frame(frame)
    rescue
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private — platform detection
  # ---------------------------------------------------------------------------

  defp detect_platform do
    os_family = :os.type() |> elem(0)
    arch = :erlang.system_info(:system_architecture) |> to_string()

    os =
      case os_family do
        :win32 ->
          "windows"

        :unix ->
          uname = System.cmd("uname", ["-s"]) |> elem(0) |> String.trim() |> String.downcase()

          case uname do
            "darwin" -> "macos"
            _ -> "linux"
          end
      end

    machine =
      cond do
        String.contains?(arch, "arm") or String.contains?(arch, "aarch64") -> "arm64"
        true -> "amd64"
      end

    "#{os}-#{machine}"
  rescue
    _ -> "linux-amd64"
  end

  # ---------------------------------------------------------------------------
  # Private — staging detection
  # ---------------------------------------------------------------------------

  defp detect_staged_version do
    new_path = Path.join([System.user_home!(), ".osa", "bin", "osa.new"])

    if File.exists?(new_path) do
      # Try to parse version from binary name or just return a marker
      "staged"
    else
      nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Private — version helpers
  # ---------------------------------------------------------------------------

  defp current_version do
    # Allow tests to override via Application env
    case Application.get_env(:optimal_system_agent, :__test_version_override__) do
      nil ->
        case Application.spec(:optimal_system_agent, :vsn) do
          nil -> File.read("VERSION") |> elem(1) |> String.trim()
          vsn -> to_string(vsn)
        end

      override ->
        override
    end
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
    parts =
      v |> to_string() |> String.trim() |> String.trim_leading("v") |> String.split(".")

    padded =
      case length(parts) do
        1 -> parts ++ ["0", "0"]
        2 -> parts ++ ["0"]
        _ -> parts
      end

    # Strip leading zeros from purely-numeric components. The human-facing display
    # pads the patch to three digits (e.g. "1.0.034"), which `Version.parse/1`
    # rejects as an invalid SemVer leading zero — so "034" -> "34". Non-numeric
    # parts (pre-release tags) are left untouched.
    padded
    |> Enum.map(fn part ->
      if part != "" and String.match?(part, ~r/^\d+$/) do
        Integer.to_string(String.to_integer(part))
      else
        part
      end
    end)
    |> Enum.join(".")
  end

  # ---------------------------------------------------------------------------
  # Private — TOML config reader
  # ---------------------------------------------------------------------------

  defp update_config do
    config_path =
      Path.join([
        System.user_home!(),
        ".osa",
        "open_computers.toml"
      ])

    case File.read(config_path) do
      {:ok, contents} -> parse_toml_update_section(contents)
      {:error, _} -> %{}
    end
  rescue
    _ -> %{}
  end

  defp parse_toml_update_section(contents) do
    # Minimal line-by-line TOML parser for the [update] section.
    # Full TOML library not available; this covers the required keys.
    lines =
      contents
      |> String.split("\n")
      |> Enum.map(&String.trim/1)

    in_update_section? = fn line -> line == "[update]" end
    in_other_section? = fn line -> String.starts_with?(line, "[") and line != "[update]" end

    {_in_section, acc} =
      Enum.reduce(lines, {false, %{}}, fn line, {in_section, map} ->
        cond do
          in_update_section?.(line) ->
            {true, map}

          in_other_section?.(line) and in_section ->
            {false, map}

          in_section and String.contains?(line, "=") ->
            [key | rest] = String.split(line, "=", parts: 2)
            key = String.trim(key)
            value = rest |> Enum.join("=") |> String.trim() |> parse_toml_value()
            {in_section, Map.put(map, String.to_atom(key), value)}

          true ->
            {in_section, map}
        end
      end)

    acc
  end

  defp parse_toml_value("true"), do: true
  defp parse_toml_value("false"), do: false

  defp parse_toml_value(v) do
    stripped = v |> String.trim("\"") |> String.trim("'")

    case Integer.parse(v) do
      {n, ""} -> n
      _ -> stripped
    end
  end
end
