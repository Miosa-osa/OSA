defmodule OptimalSystemAgent.Workspace.Trust do
  @moduledoc """
  Per-directory workspace trust (CC parity: TrustDialog + isPathTrusted).

  A workspace is trusted once the user explicitly accepts the trust prompt
  for that directory (or already accepted one of its ancestors). Until then,
  workspace-supplied executable config — project hooks, MCP servers, env
  vars, bash allow-rules — must stay inert and tools must not run there.

  ## Persistence

  `~/.osa/trusted_workspaces.json` — a map of normalized absolute path →
  `%{"trust_accepted" => true, "trust_accepted_at" => iso8601}`.
  (NOT `projects.json`: ProjectRoutes owns that file with a list schema.)

  The user's home directory and the filesystem root never receive persisted
  trust: accepting there grants session-only trust held in `:persistent_term`,
  mirroring CC's home-dir session-only behavior.

  ## Wiring status

  Self-contained. Enforcement (blocking the first tool run and deferring
  project hooks/MCP/env until accepted) is wired separately in the tool
  executor + settings layers.
  """

  require Logger

  @file_name "trusted_workspaces.json"

  # Env vars a project settings file may set without being flagged as a risk.
  @safe_env_vars ~w(OSA_THEME OSA_LOG_LEVEL OSA_LANG NO_COLOR)

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Full trust status for a directory, shaped for the TUI trust dialog.
  """
  @spec status(String.t()) :: %{
          path: String.t(),
          trusted: boolean(),
          session_only: boolean(),
          risks: [%{kind: atom(), label: String.t()}]
        }
  def status(path) do
    path = normalize(path)

    %{
      path: path,
      trusted: trusted?(path),
      session_only: session_only_path?(path),
      risks: risks(path)
    }
  end

  @doc "True when `path` (or an ancestor) has accepted trust — persisted or session."
  @spec trusted?(String.t()) :: boolean()
  def trusted?(path) do
    path = normalize(path)

    cond do
      :persistent_term.get({__MODULE__, :latch, path}, false) ->
        true

      session_trusted?(path) ->
        true

      persisted_trusted?(path) ->
        # False→true latch: trust never reverts within a running node, so
        # cache positive resolutions and skip the file walk on hot paths.
        :persistent_term.put({__MODULE__, :latch, path}, true)
        true

      true ->
        false
    end
  end

  @doc """
  Accept trust for `path`. Home / root directories get session-only trust;
  everything else is persisted with an acceptance timestamp.
  """
  @spec accept(String.t()) :: :ok
  def accept(path) do
    path = normalize(path)

    if session_only_path?(path) do
      put_session_trust(path)
    else
      entry = %{
        "trust_accepted" => true,
        "trust_accepted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      save_store(Map.put(load_store(), path, entry))
    end

    :persistent_term.put({__MODULE__, :latch, path}, true)
    Logger.info("[Trust] Workspace trusted: #{path}")
    :ok
  end

  @doc "Forget trust for `path` (exact entry only). Test/maintenance helper."
  @spec forget(String.t()) :: :ok
  def forget(path) do
    path = normalize(path)
    :persistent_term.erase({__MODULE__, :latch, path})
    put_session_set(MapSet.delete(session_set(), path))
    save_store(Map.delete(load_store(), path))
    :ok
  end

  @doc """
  Enumerate workspace-supplied executable config (CC parity:
  TrustDialog/utils.ts). Returns `[%{kind, label}]` for display in the
  trust dialog. All scans are read-only and never raise.
  """
  @spec risks(String.t()) :: [%{kind: atom(), label: String.t()}]
  def risks(path) do
    path = normalize(path)

    settings_risks(Path.join([path, ".osa", "settings.json"])) ++
      settings_risks(Path.join([path, ".osa", "settings.local.json"])) ++
      mcp_risks(Path.join(path, ".mcp.json")) ++
      hook_script_risks(Path.join([path, ".osa", "hooks"]))
  rescue
    _ -> []
  end

  # ── Private: trust resolution ─────────────────────────────────────────

  defp normalize(path), do: Path.expand(path)

  # Home + filesystem root are never persisted (too-broad trust grants).
  defp session_only_path?(path) do
    home = Path.expand(System.user_home!())
    path == home or Path.dirname(path) == path
  end

  # Persisted trust with parent-directory inheritance: trusting a folder
  # trusts everything beneath it.
  defp persisted_trusted?(path) do
    store = load_store()

    path
    |> ancestor_chain([])
    |> Enum.any?(fn dir -> match?(%{"trust_accepted" => true}, Map.get(store, dir)) end)
  end

  defp ancestor_chain(path, acc) do
    parent = Path.dirname(path)
    if parent == path, do: [path | acc], else: ancestor_chain(parent, [path | acc])
  end

  defp session_trusted?(path) do
    Enum.any?(session_set(), fn dir ->
      path == dir or String.starts_with?(path, dir <> "/")
    end)
  end

  defp session_set, do: :persistent_term.get({__MODULE__, :session}, MapSet.new())
  defp put_session_set(set), do: :persistent_term.put({__MODULE__, :session}, set)
  defp put_session_trust(path), do: put_session_set(MapSet.put(session_set(), path))

  # ── Private: store I/O ────────────────────────────────────────────────

  defp store_path do
    base = System.get_env("OSA_HOME") || Path.expand("~/.osa")
    Path.join(base, @file_name)
  end

  # Corrupt/missing store reads as empty — the trust prompt re-appears
  # (fail closed) instead of crashing startup.
  defp load_store do
    with {:ok, content} <- File.read(store_path()),
         {:ok, %{} = parsed} <- Jason.decode(content) do
      parsed
    else
      _ -> %{}
    end
  end

  defp save_store(store) do
    path = store_path()
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(store, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        _ = File.chmod(path, 0o600)
        :ok

      {:error, reason} ->
        Logger.warning("[Trust] Failed to encode trust store: #{inspect(reason)}")
        :ok
    end
  end

  # ── Private: risk enumeration ─────────────────────────────────────────

  defp settings_risks(path) do
    case read_json(path) do
      %{} = settings ->
        rel = Path.basename(Path.dirname(path)) <> "/" <> Path.basename(path)

        hooks_risk(settings, rel) ++
          env_risk(settings, rel) ++ bash_risk(settings, rel) ++ helper_risk(settings, rel)

      _ ->
        []
    end
  end

  defp hooks_risk(settings, rel) do
    case Map.get(settings, "hooks") do
      %{} = h when map_size(h) > 0 ->
        [
          %{
            kind: :hooks,
            label: "Hooks that run shell commands (#{rel}: #{Enum.join(Map.keys(h), ", ")})"
          }
        ]

      _ ->
        []
    end
  end

  defp env_risk(settings, rel) do
    case Map.get(settings, "env") do
      %{} = env when map_size(env) > 0 ->
        case Map.keys(env) -- @safe_env_vars do
          [] ->
            []

          unsafe ->
            [
              %{
                kind: :env,
                label: "Environment variables set by #{rel}: #{Enum.join(unsafe, ", ")}"
              }
            ]
        end

      _ ->
        []
    end
  end

  defp bash_risk(settings, rel) do
    settings
    |> get_in(["permissions", "allow"])
    |> List.wrap()
    |> Enum.filter(fn r -> is_binary(r) and String.starts_with?(r, "Bash(") end)
    |> case do
      [] ->
        []

      rules ->
        [%{kind: :bash_allow, label: "Pre-approved Bash rules in #{rel} (#{length(rules)})"}]
    end
  end

  defp helper_risk(settings, rel) do
    if is_binary(Map.get(settings, "apiKeyHelper")) do
      [%{kind: :api_key_helper, label: "apiKeyHelper script in #{rel}"}]
    else
      []
    end
  end

  defp mcp_risks(path) do
    case read_json(path) do
      %{"mcpServers" => %{} = servers} when map_size(servers) > 0 ->
        [
          %{
            kind: :mcp,
            label: "Project MCP servers (.mcp.json): #{Enum.join(Map.keys(servers), ", ")}"
          }
        ]

      _ ->
        []
    end
  end

  defp hook_script_risks(dir) do
    case File.ls(dir) do
      {:ok, [_ | _] = files} ->
        [%{kind: :hook_scripts, label: "Hook scripts in .osa/hooks/ (#{length(files)} file(s))"}]

      _ ->
        []
    end
  end

  defp read_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content) do
      parsed
    else
      _ -> nil
    end
  end
end
