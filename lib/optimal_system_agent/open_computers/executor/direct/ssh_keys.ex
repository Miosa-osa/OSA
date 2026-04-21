defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.SshKeys do
  @moduledoc """
  OSA-side executor for the SSH key wire protocol.

  Manages `~/.ssh/authorized_keys` for the current user (or a specified user)
  in response to frames from the MIOSA control plane.

  ## Wire protocol handled

    * Inbound (MIOSA → OSA):
        `{:ssh_key_add_request, %{key_id, pubkey, comment, user}}`
        `{:ssh_key_remove_request, %{key_id}}`
        `{:ssh_key_list_request, %{}}`

    * Outbound (OSA → MIOSA):
        `{:ssh_key_added, %{key_id}}`
        `{:ssh_key_removed, %{key_id}}`
        `{:ssh_key_list_response, %{keys: [...]}}`
        `{:ssh_key_error, %{key_id, reason}}`

  ## Safety rules

  Keys added through MIOSA are written with a trailing marker:
  `<pubkey> # miosa:<key_id>`

  The remove path filters lines containing `# miosa:<key_id>` only —
  keys added outside of MIOSA (no marker, or a different marker) are
  never touched. This prevents accidental lockout.

  ## Platform support

  | Platform | authorized_keys path              |
  |----------|-----------------------------------|
  | macOS    | `~/.ssh/authorized_keys`          |
  | Linux    | `~/.ssh/authorized_keys`          |
  | Windows  | `%USERPROFILE%\\.ssh\\authorized_keys` (OpenSSH for Windows) |

  Directory `~/.ssh` is created with mode 0700 if absent.
  File `authorized_keys` is created with mode 0600 if absent.
  Existing modes are enforced on every write.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:frame, frame})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:frame, {:ssh_key_add_request, payload}}, state) do
    Task.start(fn -> do_add(payload) end)
    {:noreply, state}
  end

  def handle_cast({:frame, {:ssh_key_remove_request, payload}}, state) do
    Task.start(fn -> do_remove(payload) end)
    {:noreply, state}
  end

  def handle_cast({:frame, {:ssh_key_list_request, payload}}, state) do
    Task.start(fn -> do_list(payload) end)
    {:noreply, state}
  end

  def handle_cast({:frame, _other}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Key operations (run in Task to avoid blocking GenServer) ──────────────────

  defp do_add(%{key_id: key_id, pubkey: pubkey} = payload) do
    # The marker must always be "# miosa:<key_id>" — the "# " prefix makes it
    # a valid SSH comment AND allows safe marker-based removal.
    raw_comment = Map.get(payload, :comment, "# miosa:#{key_id}")

    comment =
      if String.starts_with?(raw_comment, "# "),
        do: raw_comment,
        else: "# #{raw_comment}"

    auth_keys_path = authorized_keys_path(Map.get(payload, :user))

    with :ok <- ensure_ssh_dir(auth_keys_path),
         {:ok, content} <- read_or_create(auth_keys_path),
         :ok <- check_not_duplicate(content, pubkey, key_id),
         line = build_key_line(pubkey, comment),
         new_content = append_line(content, line),
         :ok <- write_authorized_keys(auth_keys_path, new_content) do
      Logger.info("[SshKeys] added key_id=#{key_id} to #{auth_keys_path}")
      FrameRouter.send_frame({:ssh_key_added, %{key_id: key_id}})
    else
      {:error, :duplicate} ->
        Logger.info("[SshKeys] key_id=#{key_id} already present — sending duplicate error")
        FrameRouter.send_frame({:ssh_key_error, %{key_id: key_id, reason: :duplicate}})

      {:error, :permission_denied} ->
        Logger.warning("[SshKeys] permission denied writing #{auth_keys_path}")
        FrameRouter.send_frame({:ssh_key_error, %{key_id: key_id, reason: :permission_denied}})

      {:error, reason} ->
        Logger.warning("[SshKeys] add failed key_id=#{key_id}: #{inspect(reason)}")
        FrameRouter.send_frame({:ssh_key_error, %{key_id: key_id, reason: :permission_denied}})
    end
  rescue
    e ->
      Logger.error("[SshKeys] unexpected error in do_add: #{inspect(e)}")

      FrameRouter.send_frame(
        {:ssh_key_error, %{key_id: payload.key_id, reason: :permission_denied}}
      )
  end

  defp do_remove(%{key_id: key_id} = payload) do
    auth_keys_path = authorized_keys_path(Map.get(payload, :user))
    marker = "# miosa:#{key_id}"

    with {:ok, content} <- File.read(auth_keys_path) do
      filtered =
        content
        |> String.split("\n")
        |> Enum.reject(fn line -> String.contains?(line, marker) end)
        |> Enum.join("\n")

      # Ensure trailing newline if content was non-empty
      filtered =
        if String.ends_with?(filtered, "\n") or filtered == "",
          do: filtered,
          else: filtered <> "\n"

      case write_authorized_keys(auth_keys_path, filtered) do
        :ok ->
          Logger.info("[SshKeys] removed key_id=#{key_id} from #{auth_keys_path}")
          FrameRouter.send_frame({:ssh_key_removed, %{key_id: key_id}})

        {:error, :permission_denied} ->
          FrameRouter.send_frame({:ssh_key_error, %{key_id: key_id, reason: :permission_denied}})

        {:error, _reason} ->
          FrameRouter.send_frame({:ssh_key_error, %{key_id: key_id, reason: :permission_denied}})
      end
    else
      {:error, :enoent} ->
        # File doesn't exist — key was never there; treat as successful removal
        Logger.info("[SshKeys] authorized_keys not found; key_id=#{key_id} treated as removed")
        FrameRouter.send_frame({:ssh_key_removed, %{key_id: key_id}})

      {:error, reason} ->
        Logger.warning("[SshKeys] read failed for remove key_id=#{key_id}: #{inspect(reason)}")
        FrameRouter.send_frame({:ssh_key_error, %{key_id: key_id, reason: :permission_denied}})
    end
  rescue
    e ->
      Logger.error("[SshKeys] unexpected error in do_remove: #{inspect(e)}")

      FrameRouter.send_frame(
        {:ssh_key_error, %{key_id: payload.key_id, reason: :permission_denied}}
      )
  end

  defp do_list(payload) do
    user = Map.get(payload, :user)
    auth_keys_path = authorized_keys_path(user)

    keys =
      case File.read(auth_keys_path) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            line = String.trim(line)

            if String.contains?(line, "# miosa:") and not String.starts_with?(line, "#") do
              # Extract the key_id from the marker
              case Regex.run(~r/# miosa:([^\s]+)$/, line) do
                [_, key_id] ->
                  parts = String.split(line, " # miosa:", parts: 2)
                  pubkey_part = List.first(parts) |> String.trim()

                  [
                    %{
                      key_id: key_id,
                      pubkey: pubkey_part,
                      fingerprint: compute_fingerprint(pubkey_part),
                      added_via: "miosa"
                    }
                  ]

                _ ->
                  []
              end
            else
              []
            end
          end)

        _ ->
          []
      end

    FrameRouter.send_frame({:ssh_key_list_response, %{keys: keys}})
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp authorized_keys_path(nil) do
    # Prefer System.get_env("HOME") over System.user_home!() because the latter
    # reads from BEAM's :init arguments (set at startup) and ignores later
    # System.put_env/2 calls — which affects test isolation.
    home = System.get_env("HOME") || System.user_home!()
    build_path(home)
  end

  defp authorized_keys_path(user) when is_binary(user) and user != "" do
    # On Unix: /home/<user> or /Users/<user>; on Windows: C:\Users\<user>
    # We resolve via getpwnam-equivalent using the home path logic.
    # For safety, only allow the current user's home — multi-user support is
    # intentionally out of scope for v1.
    Logger.warning("[SshKeys] user= field ignored; writing to current user's authorized_keys")
    authorized_keys_path(nil)
  end

  defp authorized_keys_path(_), do: authorized_keys_path(nil)

  defp build_path(home) do
    case :os.type() do
      {:win32, _} ->
        Path.join([home, ".ssh", "authorized_keys"])

      _ ->
        Path.join([home, ".ssh", "authorized_keys"])
    end
  end

  defp ensure_ssh_dir(auth_keys_path) do
    ssh_dir = Path.dirname(auth_keys_path)

    case File.mkdir_p(ssh_dir) do
      :ok ->
        # Set 0700 on the directory
        case set_permissions(ssh_dir, 0o700) do
          :ok -> :ok
          # Best-effort on Windows or restricted systems
          {:error, _} -> :ok
        end

      {:error, :eacces} ->
        {:error, :permission_denied}

      {:error, _} ->
        :ok
    end
  end

  defp read_or_create(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        # Create empty file with 0600 permissions
        case File.write(path, "") do
          :ok ->
            set_permissions(path, 0o600)
            {:ok, ""}

          {:error, :eacces} ->
            {:error, :permission_denied}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :eacces} ->
        {:error, :permission_denied}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_not_duplicate(content, pubkey, key_id) do
    # Check if the exact same key body (base64 part) is already present
    # Use the key body (second token) for comparison to avoid false mismatches
    # from different comments. Also check our own marker to catch exact duplicates.
    key_body =
      pubkey
      |> String.trim()
      |> String.split(" ")
      |> Enum.at(1)

    marker = "# miosa:#{key_id}"

    lines = String.split(content, "\n")

    already_present_by_marker =
      Enum.any?(lines, fn line -> String.contains?(line, marker) end)

    already_present_by_body =
      key_body != nil and
        Enum.any?(lines, fn line ->
          trimmed = String.trim(line)
          not String.starts_with?(trimmed, "#") and String.contains?(trimmed, key_body)
        end)

    if already_present_by_marker or already_present_by_body do
      {:error, :duplicate}
    else
      :ok
    end
  end

  defp build_key_line(pubkey, comment) do
    # Normalize: strip trailing comments from pubkey, then append our marker
    parts = String.split(String.trim(pubkey), " ")

    base_key =
      case parts do
        [type, body | _rest] -> "#{type} #{body}"
        _ -> String.trim(pubkey)
      end

    "#{base_key} #{comment}"
  end

  defp append_line(content, line) do
    # Ensure we add to a fresh line
    if content == "" or String.ends_with?(content, "\n") do
      content <> line <> "\n"
    else
      content <> "\n" <> line <> "\n"
    end
  end

  defp write_authorized_keys(path, content) do
    case File.write(path, content) do
      :ok ->
        set_permissions(path, 0o600)
        :ok

      {:error, :eacces} ->
        {:error, :permission_denied}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp set_permissions(path, mode) do
    case :os.type() do
      {:win32, _} ->
        # Windows: icacls-based permission setting is complex; skip for v1.
        # OpenSSH for Windows enforces ACLs independently.
        :ok

      _ ->
        case File.chmod(path, mode) do
          :ok -> :ok
          # Best-effort; don't fail the key add
          {:error, _reason} -> :ok
        end
    end
  end

  defp compute_fingerprint(pubkey_line) do
    with [_type, b64 | _] <- String.split(String.trim(pubkey_line), " "),
         {:ok, key_bytes} <- Base.decode64(b64) do
      hash = :crypto.hash(:sha256, key_bytes)
      "SHA256:#{Base.encode64(hash, padding: false)}"
    else
      _ -> "unknown"
    end
  end
end
