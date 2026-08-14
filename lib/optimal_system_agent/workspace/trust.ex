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
          config_changed: boolean(),
          risks: [%{kind: atom(), label: String.t()}]
        }
  def status(path) do
    path = normalize(path)

    %{
      path: path,
      trusted: trusted?(path),
      session_only: session_only_path?(path),
      # True when this directory WAS trusted and its executable config has
      # since changed. The dialog should say "re-accept because the config
      # changed", not "this workspace is untrusted" — they are different
      # situations and the user's next action differs.
      config_changed: config_changed?(path),
      risks: risks(path)
    }
  end

  @doc """
  True when `path` has a persisted grant whose pinned digest no longer matches
  the workspace's current executable config.
  """
  @spec config_changed?(String.t()) :: boolean()
  def config_changed?(path) do
    path = normalize(path)

    case Map.get(load_store(), path) do
      %{"trust_accepted" => true, "config_digest" => pinned} when is_binary(pinned) ->
        pinned != security_digest(path)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  @doc """
  True when `path` (or an ancestor) has accepted trust — persisted or session.

  ## Content pinning

  An EXACT-match persisted grant is pinned to the security-relevant content of
  the workspace's config files at the moment trust was accepted (see
  `security_digest/1`). Accepting trust once must not be a standing grant over
  whatever that repository's config becomes later: a `git pull` that adds a
  `PreToolUse` hook, an `env` entry or an MCP server is new executable config
  that the user never saw, and it re-prompts instead of applying silently.

  Two deliberate exemptions:

    * **Non-security keys are not pinned.** Editing `skin`, `model`,
      `verbose` — anything outside the security surface — never re-prompts.
      Only `permissions`, `permission_mode`, `env`, `hooks`, `apiKeyHelper`,
      `mcpServers` and the `.osa/hooks/` scripts participate in the digest.
    * **Inherited trust is not pinned.** Trusting a parent directory
      (e.g. `~/projects`) is a deliberately broad grant over everything
      beneath it; re-prompting per child would make that grant meaningless.
      Only the exact directory the user accepted carries a digest.

  Grants written before pinning existed carry no digest and stay trusted
  (grandfathered) — they are re-pinned on the next `accept/1`.
  """
  @spec trusted?(String.t()) :: boolean()
  def trusted?(path) do
    path = normalize(path)

    cond do
      # Latch, invalidated by config changes: it stores the cheap stat
      # signature it was proven against, so editing a config file drops the
      # latch and forces a fresh digest comparison rather than a stale yes.
      latched?(path) ->
        true

      session_trusted?(path) ->
        true

      persisted_trusted?(path) ->
        :persistent_term.put({__MODULE__, :latch, path}, config_sig(path))
        true

      true ->
        false
    end
  end

  defp latched?(path) do
    case :persistent_term.get({__MODULE__, :latch, path}, :none) do
      :none -> false
      sig -> sig == config_sig(path)
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
        "trust_accepted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        # Pins the grant to the executable config the user is accepting RIGHT
        # NOW. Config that arrives later (git pull, editor) re-prompts.
        "config_digest" => security_digest(path)
      }

      save_store(Map.put(load_store(), path, entry))
    end

    :persistent_term.put({__MODULE__, :latch, path}, config_sig(path))
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
  #
  # The EXACT-match grant is additionally pinned to the config digest captured
  # at accept time; an INHERITED grant (from an ancestor) is not, because
  # trusting a parent is a deliberately broad grant and per-child re-prompting
  # would defeat it. See `trusted?/1`.
  defp persisted_trusted?(path) do
    store = load_store()

    case Map.get(store, path) do
      %{"trust_accepted" => true} = entry ->
        digest_matches?(entry, path)

      _ ->
        path
        |> ancestor_chain([])
        |> Enum.reject(&(&1 == path))
        |> Enum.any?(fn dir -> match?(%{"trust_accepted" => true}, Map.get(store, dir)) end)
    end
  end

  # Grants written before pinning existed carry no digest — grandfathered.
  defp digest_matches?(%{"config_digest" => pinned}, path) when is_binary(pinned) do
    case security_digest(path) do
      ^pinned ->
        true

      _ ->
        warn_config_changed(path)
        false
    end
  end

  defp digest_matches?(_entry, _path), do: true

  defp warn_config_changed(path) do
    key = {__MODULE__, :warned_changed, path, config_sig(path)}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.warning(
        "[Trust] Executable config in #{path} CHANGED since you trusted it — permission rules, " <>
          "env, hooks and MCP servers there are being WITHHELD until you re-accept. This is what " <>
          "a `git pull` that adds a hook looks like. Review the changes, then `/trust accept`."
      )
    end

    :ok
  rescue
    _ -> :ok
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

  # ── Content pinning ───────────────────────────────────────────────────

  # Workspace files that can carry executable config, relative to the root.
  @config_files [
    ".osa/settings.json",
    ".osa/settings.local.json",
    ".mcp.json",
    ".osa/mcp.local.json"
  ]

  # The only keys that participate in the pin. Everything else in a settings
  # file (skin, model, verbose, …) is a preference: editing it must never cost
  # the user a re-prompt. Keep this list in sync with what `trusted_layer/1`
  # in `Settings` actually withholds.
  @security_keys ~w(permissions permission_mode env hooks apiKeyHelper mcpServers)

  @doc """
  Stable digest of the SECURITY-RELEVANT workspace config under `path`.

  Covers the `@security_keys` of every file in `@config_files` plus the name
  and content of every script in `.osa/hooks/`. Two directories with identical
  executable config produce the same digest regardless of key order, whitespace
  or unrelated preference keys.
  """
  @spec security_digest(String.t()) :: String.t()
  def security_digest(path) do
    path = normalize(path)

    payload =
      Enum.map(@config_files, fn rel ->
        {rel, security_subset(read_json(Path.join(path, rel)))}
      end) ++ [{"__hooks__", hook_script_digest(Path.join([path, ".osa", "hooks"]))}]

    :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
    |> Base.encode16(case: :lower)
  rescue
    # A digest we cannot compute must not read as "unchanged".
    _ -> "unavailable"
  end

  defp security_subset(%{} = json), do: Map.take(json, @security_keys)
  defp security_subset(_), do: %{}

  defp hook_script_digest(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.sort()
        |> Enum.map(fn f ->
          {f,
           case File.read(Path.join(dir, f)) do
             {:ok, content} -> :crypto.hash(:sha256, content)
             _ -> :unreadable
           end}
        end)

      _ ->
        []
    end
  end

  # Cheap change detector for the hot path: {mtime, size} of each config file.
  # A stat is far cheaper than read+parse+hash, so the latch re-validates on
  # every call while the full digest is computed only when a file has moved.
  defp config_sig(path) do
    # `.osa/hooks/` is included as a directory stat AND a per-file stat: editing
    # a hook script in place changes the file's mtime but not the directory's.
    hooks_dir = Path.join([path, ".osa", "hooks"])

    hook_entries =
      case File.ls(hooks_dir) do
        {:ok, files} -> Enum.sort(files) |> Enum.map(&Path.join([".osa", "hooks", &1]))
        _ -> []
      end

    Enum.map(@config_files ++ hook_entries ++ [".osa/hooks"], fn rel ->
      case File.stat(Path.join(path, rel), time: :posix) do
        {:ok, %{mtime: m, size: s}} -> {rel, m, s}
        _ -> {rel, nil, nil}
      end
    end)
  rescue
    _ -> :error
  end

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
