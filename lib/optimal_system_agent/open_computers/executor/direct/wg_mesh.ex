defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.WgMesh do
  @moduledoc """
  WireGuard mesh networking executor for OpenComputers.

  Manages WireGuard interfaces on this host for each mesh network the host
  participates in. One GenServer manages all meshes on this OSA instance.

  ## Wire protocol handled

    * `{:wg_init_request, payload}` — MIOSA → OSA
        Generates a keypair if needed, installs wireguard-tools if missing,
        reports the pubkey back via `wg_pubkey`.

    * `{:wg_configure, payload}` — MIOSA → OSA
        Writes the wg-quick config file and brings the interface up.
        Emits `wg_configured` on success, `wg_error` on failure.

    * `{:wg_teardown_request, payload}` — MIOSA → OSA
        Brings the interface down, removes config file (keeps private key).
        Emits `wg_torn_down`.

  ## Periodic reporting

  Every 60 seconds, `wg show <interface>` is parsed and a `wg_status` frame
  is emitted for each active mesh.

  ## Platform support

    * macOS — brew install wireguard-tools. Requires sudo for wg-quick.
    * Linux (Debian/Ubuntu) — apt-get install -y wireguard-tools
    * Linux (RHEL/Fedora) — dnf install -y wireguard-tools
    * Windows — NOT YET SUPPORTED. Emits wg_error :wireguard_not_available
                with message directing users to install WireGuard manually.

  ## Sudo handling

  `wg-quick` requires root to create/destroy network interfaces. On macOS,
  the user is prompted once during setup to add a NOPASSWD sudoers entry
  for `wg-quick`:

      your_user ALL=(ALL) NOPASSWD: /usr/local/bin/wg-quick
      your_user ALL=(ALL) NOPASSWD: /opt/homebrew/bin/wg-quick

  If sudo is not available, a `wg_error` with reason `:not_root` is emitted.
  Alternative: wireguard-go (userspace) is available on macOS and does NOT
  require sudo — future enhancement, tracked as TODO.

  ## Key management

  Private keys are stored at `~/.osa/wg/mesh_<id>_private`.
  They NEVER leave the host. Only the derived public key is sent to MIOSA.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @status_interval_ms 60_000

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Route an inbound frame to this executor."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:inbound, frame})
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Schedule periodic status reporting
    :timer.send_interval(@status_interval_ms, :status_tick)
    {:ok, %{meshes: %{}}}
  end

  # ── Inbound frame handlers ────────────────────────────────────────────────────

  @impl true
  def handle_cast({:inbound, {:wg_init_request, payload}}, state) do
    mesh_id = payload.mesh_id
    Logger.info("[WgMesh] wg_init_request mesh=#{mesh_id}")

    case handle_init_request(payload) do
      {:ok, pubkey, installed_version} ->
        endpoint_hint = detect_public_ip()

        FrameRouter.send_frame({
          :wg_pubkey,
          %{
            mesh_id: mesh_id,
            pubkey: pubkey,
            installed_version: installed_version,
            endpoint_hint: endpoint_hint
          }
        })

        mesh_entry = %{
          mesh_id: mesh_id,
          assigned_ip: payload.assigned_ip,
          listen_port: payload.listen_port,
          private_network: payload.private_network
        }

        {:noreply, put_in(state.meshes[mesh_id], mesh_entry)}

      {:error, reason} ->
        Logger.error("[WgMesh] init failed mesh=#{mesh_id} reason=#{inspect(reason)}")

        FrameRouter.send_frame({
          :wg_error,
          %{mesh_id: mesh_id, reason: reason}
        })

        {:noreply, state}
    end
  end

  def handle_cast({:inbound, {:wg_configure, payload}}, state) do
    mesh_id = payload.mesh_id
    Logger.info("[WgMesh] wg_configure mesh=#{mesh_id} peers=#{length(payload.peers)}")

    case state.meshes[mesh_id] do
      nil ->
        Logger.warning("[WgMesh] wg_configure for unknown mesh=#{mesh_id} — ignoring")
        {:noreply, state}

      mesh ->
        case apply_config(mesh, payload) do
          :ok ->
            FrameRouter.send_frame({:wg_configured, %{mesh_id: mesh_id}})

          {:error, reason} ->
            Logger.error("[WgMesh] configure failed mesh=#{mesh_id} reason=#{inspect(reason)}")

            FrameRouter.send_frame({
              :wg_error,
              %{mesh_id: mesh_id, reason: reason}
            })
        end

        {:noreply, state}
    end
  end

  def handle_cast({:inbound, {:wg_teardown_request, %{mesh_id: mesh_id}}}, state) do
    Logger.info("[WgMesh] wg_teardown_request mesh=#{mesh_id}")

    case teardown_interface(mesh_id) do
      :ok ->
        FrameRouter.send_frame({:wg_torn_down, %{mesh_id: mesh_id}})

      {:error, reason} ->
        Logger.error("[WgMesh] teardown failed mesh=#{mesh_id} reason=#{inspect(reason)}")

        FrameRouter.send_frame({
          :wg_error,
          %{mesh_id: mesh_id, reason: :teardown_failed}
        })
    end

    {:noreply, Map.update!(state, :meshes, &Map.delete(&1, mesh_id))}
  end

  def handle_cast({:inbound, frame}, state) do
    Logger.debug("[WgMesh] unhandled inbound frame: #{inspect(elem(frame, 0))}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:status_tick, state) do
    Enum.each(state.meshes, fn {mesh_id, _mesh} ->
      case read_wg_status(mesh_id) do
        {:ok, peers} ->
          FrameRouter.send_frame({
            :wg_status,
            %{mesh_id: mesh_id, peers: peers}
          })

        {:error, _reason} ->
          # Interface not yet up — normal during init
          :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Init request handler ──────────────────────────────────────────────────────

  defp handle_init_request(payload) do
    mesh_id = payload.mesh_id

    with :ok <- ensure_wireguard_installed(),
         {:ok, pubkey} <- ensure_keypair(mesh_id) do
      installed_version = wg_version()
      {:ok, pubkey, installed_version}
    end
  end

  # ── WireGuard installation ────────────────────────────────────────────────────

  defp ensure_wireguard_installed do
    if wg_available?() do
      :ok
    else
      Logger.info("[WgMesh] wireguard-tools not found — attempting install")
      install_wireguard()
    end
  end

  defp wg_available? do
    case System.find_executable("wg") do
      nil -> false
      _ -> true
    end
  end

  defp wg_version do
    case System.cmd("wg", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp install_wireguard do
    case platform() do
      :macos ->
        Logger.info("[WgMesh] installing wireguard-tools via brew")

        case System.cmd("brew", ["install", "wireguard-tools"],
               stderr_to_stdout: true,
               into: IO.stream()
             ) do
          {_, 0} -> :ok
          {_, _} -> {:error, :install_failed}
        end

      {:linux, :debian} ->
        Logger.info("[WgMesh] installing wireguard-tools via apt-get")

        case System.cmd("sudo", ["apt-get", "install", "-y", "wireguard-tools"],
               stderr_to_stdout: true,
               into: IO.stream()
             ) do
          {_, 0} -> :ok
          {_, _} -> {:error, :install_failed}
        end

      {:linux, :rhel} ->
        Logger.info("[WgMesh] installing wireguard-tools via dnf")

        case System.cmd("sudo", ["dnf", "install", "-y", "wireguard-tools"],
               stderr_to_stdout: true,
               into: IO.stream()
             ) do
          {_, 0} -> :ok
          {_, _} -> {:error, :install_failed}
        end

      :windows ->
        Logger.warning("[WgMesh] WireGuard on Windows is not yet supported")
        {:error, :wireguard_not_available}

      {:linux, :unknown} ->
        Logger.warning("[WgMesh] unknown Linux distro — cannot auto-install wireguard-tools")
        {:error, :wireguard_not_available}
    end
  rescue
    e ->
      Logger.error("[WgMesh] install exception: #{inspect(e)}")
      {:error, :install_failed}
  end

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:win32, _} -> :windows
      {:unix, _} -> detect_linux_distro()
    end
  end

  defp detect_linux_distro do
    cond do
      File.exists?("/etc/debian_version") -> {:linux, :debian}
      File.exists?("/etc/fedora-release") -> {:linux, :rhel}
      File.exists?("/etc/redhat-release") -> {:linux, :rhel}
      true -> {:linux, :unknown}
    end
  end

  # ── Keypair management ────────────────────────────────────────────────────────

  defp ensure_keypair(mesh_id) do
    priv_path = private_key_path(mesh_id)

    if File.exists?(priv_path) do
      # Reuse existing private key — derive pubkey
      derive_pubkey(priv_path)
    else
      generate_keypair(mesh_id, priv_path)
    end
  end

  defp generate_keypair(mesh_id, priv_path) do
    :ok = File.mkdir_p!(wg_dir())

    Logger.info("[WgMesh] generating WireGuard keypair for mesh=#{mesh_id}")

    case System.cmd("wg", ["genkey"]) do
      {private_key, 0} ->
        private_key = String.trim(private_key)
        File.write!(priv_path, private_key)
        # Restrict permissions (owner read-only)
        File.chmod!(priv_path, 0o600)
        derive_pubkey_from_string(private_key)

      {output, code} ->
        Logger.error("[WgMesh] wg genkey failed exit=#{code} output=#{output}")
        {:error, :config_failed}
    end
  end

  defp derive_pubkey(priv_path) do
    private_key = File.read!(priv_path) |> String.trim()
    derive_pubkey_from_string(private_key)
  end

  defp derive_pubkey_from_string(private_key) do
    case System.cmd("wg", ["pubkey"], input: private_key) do
      {pubkey, 0} -> {:ok, String.trim(pubkey)}
      {output, code} ->
        Logger.error("[WgMesh] wg pubkey failed exit=#{code} output=#{output}")
        {:error, :config_failed}
    end
  end

  # ── Config application ────────────────────────────────────────────────────────

  defp apply_config(mesh, configure_payload) do
    mesh_id = mesh.mesh_id
    priv_path = private_key_path(mesh_id)
    conf_path = config_file_path(mesh_id)
    iface_name = interface_name(mesh_id)

    if not File.exists?(priv_path) do
      Logger.error("[WgMesh] private key missing for mesh=#{mesh_id}")
      {:error, :config_failed}
    else
      private_key = File.read!(priv_path) |> String.trim()

      config_content = build_wg_config(
        private_key,
        mesh.assigned_ip,
        mesh.listen_port,
        configure_payload.peers,
        configure_payload.preshared_keys
      )

      File.write!(conf_path, config_content)

      # Bring down any existing interface (idempotent)
      bring_down_interface(iface_name)

      case bring_up_interface(conf_path, iface_name) do
        :ok ->
          Logger.info("[WgMesh] interface #{iface_name} up for mesh=#{mesh_id}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_wg_config(private_key, assigned_ip, listen_port, peers, preshared_keys) do
    peer_sections =
      peers
      |> Enum.filter(& &1.pubkey)
      |> Enum.map(fn peer ->
        psk = Map.get(preshared_keys, peer.pubkey)

        lines = [
          "[Peer]",
          "PublicKey = #{peer.pubkey}",
          "AllowedIPs = #{peer.allowed_ips}",
          if(psk, do: "PresharedKey = #{psk}", else: nil),
          if(peer.endpoint, do: "Endpoint = #{peer.endpoint}", else: nil),
          "PersistentKeepalive = #{peer.persistent_keepalive || 25}"
        ]

        lines
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)
      |> Enum.join("\n\n")

    """
    [Interface]
    Address = #{assigned_ip}
    ListenPort = #{listen_port}
    PrivateKey = #{private_key}

    #{peer_sections}
    """
  end

  defp bring_up_interface(conf_path, iface_name) do
    wg_quick = find_wg_quick()

    case System.cmd("sudo", [wg_quick, "up", conf_path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _code} ->
        cond do
          String.contains?(output, "Operation not permitted") or
              String.contains?(output, "sudo") ->
            Logger.error("[WgMesh] sudo required for wg-quick — #{sudo_help_message()}")
            {:error, :not_root}

          true ->
            Logger.error("[WgMesh] wg-quick up failed for #{iface_name}: #{output}")
            {:error, :config_failed}
        end
    end
  rescue
    e ->
      Logger.error("[WgMesh] bring_up exception: #{inspect(e)}")
      {:error, :config_failed}
  end

  defp bring_down_interface(iface_name) do
    wg_quick = find_wg_quick()
    conf_path = config_file_path_from_iface(iface_name)

    System.cmd("sudo", [wg_quick, "down", conf_path], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp teardown_interface(mesh_id) do
    iface_name = interface_name(mesh_id)
    conf_path = config_file_path(mesh_id)

    bring_down_interface(iface_name)
    File.rm(conf_path)
    # Note: private key is NOT removed — mesh can re-form without re-keying
    :ok
  end

  # ── Status parsing ────────────────────────────────────────────────────────────

  defp read_wg_status(mesh_id) do
    iface_name = interface_name(mesh_id)

    case System.cmd("wg", ["show", iface_name, "dump"], stderr_to_stdout: true) do
      {output, 0} ->
        peers = parse_wg_dump(output)
        {:ok, peers}

      {_output, _code} ->
        {:error, :interface_not_found}
    end
  rescue
    _ -> {:error, :wg_not_available}
  end

  # `wg show <iface> dump` output format (tab-separated):
  # Line 1: interface — private_key public_key listen_port fwmark
  # Remaining lines: peers — pubkey preshared_key endpoint allowed_ips
  #                          latest_handshake rx_bytes tx_bytes persistent_keepalive
  defp parse_wg_dump(output) do
    lines = String.split(output, "\n", trim: true)

    # Skip the interface line (first line)
    lines
    |> Enum.drop(1)
    |> Enum.map(fn line ->
      parts = String.split(line, "\t")

      case parts do
        [pubkey, _psk, endpoint, _allowed_ips, latest_handshake_s, rx_bytes_s, tx_bytes_s | _] ->
          latest_handshake =
            case Integer.parse(latest_handshake_s) do
              {n, _} when n > 0 -> n
              _ -> 0
            end

          %{
            pubkey: pubkey,
            endpoint: if(endpoint == "(none)", do: nil, else: endpoint),
            latest_handshake: latest_handshake,
            rx_bytes: parse_int(rx_bytes_s),
            tx_bytes: parse_int(tx_bytes_s)
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> 0
    end
  end

  # ── Public IP detection ───────────────────────────────────────────────────────

  defp detect_public_ip do
    # Try to detect our public IP + WireGuard listen port for endpoint_hint.
    # Best-effort — returns nil if offline or STUN/HTTP unavailable.
    # STUN integration is deferred (TODO): use a STUN server to discover
    # the public UDP endpoint for holepunching behind NAT.
    case System.cmd("curl", ["-sf", "--max-time", "3", "https://api4.ipify.org"],
           stderr_to_stdout: false
         ) do
      {ip, 0} ->
        ip = String.trim(ip)
        if ip =~ ~r/^\d+\.\d+\.\d+\.\d+$/, do: ip, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ── Path helpers ──────────────────────────────────────────────────────────────

  defp wg_dir do
    home = System.user_home!()
    Path.join([home, ".osa", "wg"])
  end

  defp private_key_path(mesh_id) do
    Path.join(wg_dir(), "mesh_#{mesh_id}_private")
  end

  defp config_file_path(mesh_id) do
    Path.join(wg_dir(), "#{interface_name(mesh_id)}.conf")
  end

  defp config_file_path_from_iface(iface_name) do
    Path.join(wg_dir(), "#{iface_name}.conf")
  end

  # Interface names must be ≤ 15 chars on Linux (IFNAMSIZ=16 including null).
  # Use "wgm" prefix + first 12 chars of mesh_id (hex portion, no hyphens).
  defp interface_name(mesh_id) do
    hex = String.replace(mesh_id, "-", "") |> String.slice(0, 8)
    "wgm#{hex}"
  end

  defp find_wg_quick do
    System.find_executable("wg-quick") ||
      "/usr/local/bin/wg-quick" ||
      "/opt/homebrew/bin/wg-quick"
  end

  defp sudo_help_message do
    wg_quick_path = find_wg_quick()

    """
    To allow OSA to manage WireGuard interfaces without a password prompt,
    run: sudo visudo
    Then add:
      #{System.user_home!() |> Path.basename()} ALL=(ALL) NOPASSWD: #{wg_quick_path}
    """
  end
end
