defmodule OptimalSystemAgent.Settings do
  @moduledoc """
  Multi-layer settings cascade.

  Settings are resolved through 4 layers (highest priority last):

  1. **User** — `~/.osa/settings.json` (global user preferences)
  2. **Project** — `.osa/settings.json` (checked into repo, shared with team)
  3. **Local** — `.osa/settings.local.json` (gitignored, per-developer overrides)
  4. **Flag** — file named by `--settings <file>` / `OSA_SETTINGS` (optional)
  5. **Session** — in-memory only, set via API or CLI commands

  Layers are DEEP-merged: nested maps merge recursively, arrays concatenate
  and dedupe, higher-priority scalars win (explicit `false`/`null` included —
  presence-based, no falsy fallthrough).

  File reads are cached in the `:osa_settings_cache` ETS table keyed by
  `{path, {mtime, size}}`; `reset_cache/0` is the single reset, called by the
  file watcher and by every internal write.

  ## Session scoping (and what is still not scoped)

  The FILE layers resolve against `Workspace.Cwd.get/0`, which is already
  per-process: the agent loop publishes the session's `working_dir` into the
  process dictionary at the start of every turn, so two sessions in two
  different directories genuinely read two different `.osa/settings.local.json`
  files. What was NOT scoped is the **session layer itself**: `set_session/2`
  wrote a single daemon-wide `{{:session, key}, value}` row, so "session"
  settings were shared by every concurrent session in the backend. That is what
  made per-session policy (e.g. disabling network tools for one run) impossible
  — not the cwd.

  The session layer now has two scopes:

    * `:global` — rows written with no session in context. Unchanged key shape,
      unchanged behaviour, still daemon-wide.
    * a session id — rows written by (or for) one session. They shadow the
      global rows for that session only.

  A process states which session it is acting for via `:osa_session_id` in its
  process dictionary (published by the loop's turn pipeline, exactly like the
  cwd override); `set_session_for/3` addresses a session explicitly, and
  `clear_session/1` drops its rows.

  **Still not scoped, deliberately:** two sessions sharing one working directory
  share their `:project`/`:local` file layers, because those are properties of
  the directory, not of the session. A complete fix would add a per-session
  OVERLAY above the flag layer — a settings map handed to a session at creation
  (HTTP `POST /sessions`, `mix osa.run --settings-json`, subagent spawn) and
  carried in the loop state rather than in ETS — so a caller could impose policy
  on a session it does not run inside, without touching any file or any other
  session. The scoping mechanism here is the prerequisite for that; the wiring
  of the session-creation surfaces is not done.
  """
  require Logger

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.System.AtomicFile
  alias OptimalSystemAgent.Utils.Bom

  # Runtime-resolved so a prebuilt release uses the END USER's home, not the CI
  # runner's baked-in path. Resolved on every call via ConfigFile.config_dir/0.
  defp user_settings, do: Path.join(ConfigFile.config_dir(), "settings.json")

  @cache_table :osa_settings_cache

  @doc """
  Get a setting by key, resolved through the deep-merged cascade.

  Resolution is presence-based (`Map.fetch` on the merged map), so an explicit
  `false` or `null` in a higher-priority layer is honored instead of falling
  through to a lower layer or the default (CC `updateSettingsForSource`
  semantics).
  """
  def get(key, default \\ nil) do
    case Map.fetch(merged(), to_string(key)) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  All settings deep-merged through the cascade (lowest → highest priority):
  user → project → local → flag file → session.
  """
  def merged do
    [layer(:user), layer(:project), layer(:local), layer(:flag)]
    |> Enum.reduce(%{}, &deep_merge(&2, &1))
    |> deep_merge(get_all_session())
    |> harden_if_unparseable()
  end

  @doc "Deep-merge two settings maps: maps merge recursively, lists concat + dedupe, scalars override."
  def deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _k, a, b when is_map(a) and is_map(b) -> deep_merge(a, b)
      _k, a, b when is_list(a) and is_list(b) -> Enum.uniq(a ++ b)
      _k, _a, b -> b
    end)
  end

  @doc """
  Apply the merged `\"env\"` settings key to the OS environment.

  Only string → string entries are applied. Called at boot and re-applied
  live by `Settings.Watcher` whenever a settings file changes on disk.
  """
  def apply_env_settings do
    # Trust-gated: `env` from a checked-in `.osa/settings.json` is
    # workspace-supplied executable config (PATH, loader vars). An untrusted
    # clone must not be able to set it — same gate as project hooks and
    # permission rules.
    case Map.get(merged_trusted(), "env") do
      env when is_map(env) ->
        Enum.each(env, fn
          {k, v} when is_binary(k) and is_binary(v) ->
            try do
              System.put_env(k, v)
            rescue
              _ -> Logger.warning("[settings] Invalid env var name in settings: #{inspect(k)}")
            end

          _ ->
            :ok
        end)

      _ ->
        :ok
    end
  end

  @doc "Drop every cached settings file read (single reset — next read re-parses)."
  def reset_cache do
    :ets.delete_all_objects(@cache_table)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Absolute paths of all file-backed settings sources (watched for changes)."
  def source_paths do
    [user_settings(), project_settings_path(), local_settings_path()] ++
      List.wrap(flag_settings_path())
  end

  @doc """
  Set a session-level setting (in-memory only, not persisted).

  Scoped to the CURRENT session when one is resolvable from the calling process
  (`Settings.current_session/0`), and to the daemon-wide `:global` scope
  otherwise — see the "Session scoping" section of the moduledoc.
  """
  def set_session(key, value), do: put_session(current_session(), key, value)

  @doc """
  Set a session-level setting for a SPECIFIC session id.

  This is the entry point for per-session policy (e.g. "no network tools for
  this benchmark run"): the value is visible only to code running on behalf of
  `session_id`, and is invisible to every other concurrent session.
  """
  @spec set_session_for(String.t() | nil, atom() | String.t(), term()) :: :ok
  def set_session_for(session_id, key, value) when is_binary(session_id) and session_id != "",
    do: put_session(session_id, key, value)

  def set_session_for(_session_id, key, value), do: put_session(:global, key, value)

  @doc """
  Drop every session-scoped setting for `session_id` (call on session end).

  Without this the ETS table grows one row per {session, key} for the daemon's
  whole lifetime.
  """
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) when is_binary(session_id) do
    :ets.match_delete(:osa_settings, {{:session, session_id, :_}, :_})
    :ok
  rescue
    _ -> :ok
  end

  def clear_session(_), do: :ok

  @doc """
  The session id the current process is acting for, or `:global`.

  Resolution mirrors `Workspace.Cwd.get/0`: a process-dictionary value published
  by the agent loop at the start of every turn (`:osa_session_id`), else no
  session at all. There is deliberately no node-wide fallback — guessing "the"
  session is how a per-session setting silently becomes a global one.
  """
  @spec current_session() :: String.t() | :global
  def current_session do
    case Process.get(:osa_session_id) do
      sid when is_binary(sid) and sid != "" -> sid
      _ -> :global
    end
  end

  defp put_session(:global, key, value) do
    # NB: the global row keeps its original 2-element key shape so existing
    # readers/writers of `{{:session, key}, value}` are unaffected.
    :ets.insert(:osa_settings, {{:session, key}, value})
    :ok
  rescue
    _ -> :ok
  end

  defp put_session(session_id, key, value) do
    :ets.insert(:osa_settings, {{:session, session_id, to_string(key)}, value})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Set a user-level setting (persisted to ~/.osa/settings.json).

  Refuses to overwrite an existing-but-unparseable settings file — returns
  `{:error, :corrupt_settings_file}` so a corrupt file is never clobbered.
  """
  def set_user(key, value), do: set_in_file(user_settings(), key, value)

  @doc "Set a project-level setting (persisted to .osa/settings.json). Refuses to overwrite a corrupt file."
  def set_project(key, value), do: set_in_file(project_settings_path(), key, value)

  @doc "Delete a key from the user settings file (write-side delete semantics)."
  def delete_user(key), do: update_in_file(user_settings(), &Map.delete(&1, to_string(key)))

  @doc "Delete a key from the project settings file."
  def delete_project(key),
    do: update_in_file(project_settings_path(), &Map.delete(&1, to_string(key)))

  defp set_in_file(path, key, value),
    do: update_in_file(path, &Map.put(&1, to_string(key), value))

  defp update_in_file(path, fun) do
    case load_json_for_write(path) do
      {:ok, settings} ->
        # Register the internal write BEFORE touching the file so the watcher
        # can never observe the change in the gap before suppression lands.
        OptimalSystemAgent.Settings.Watcher.note_internal_write(path)
        result = write_json(path, fun.(settings))
        reset_cache()
        result

      {:error, :corrupt} ->
        Logger.warning(
          "[settings] Refusing to overwrite corrupt settings file #{path} — fix or delete it first"
        )

        {:error, :corrupt_settings_file}
    end
  end

  @doc "Get all settings merged (for /settings API endpoint)."
  def all, do: merged()

  @doc """
  Like `layer/1`, but the PROJECT layer is gated behind workspace trust.

  `.osa/settings.json` is checked into the repo, so it is workspace-supplied
  config: cloning a hostile repository must not hand it permission rules or a
  `permission_mode` before the user has been asked whether they trust the
  workspace. Every security-relevant read of the cascade goes through here
  (and `get_trusted/2` / `merged_trusted/0`) rather than `layer/1`.

  This is the SAME `project_trusted?/0` gate `get_merged_hooks/0` already
  applies to project hooks — one trust concept, two consumers. User, local,
  flag and session layers are authored on this machine and always apply.
  """
  @spec trusted_layer(atom()) :: map()
  def trusted_layer(:project) do
    if project_trusted?() do
      layer(:project)
    else
      case layer(:project) do
        empty when empty == %{} -> %{}
        _ -> warn_project_withheld()
      end
    end
  end

  def trusted_layer(source), do: layer(source)

  @doc """
  `merged/0` with the project layer gated behind workspace trust.
  Use for any security-relevant setting; `merged/0` stays as-is for display.
  """
  def merged_trusted do
    [layer(:user), trusted_layer(:project), layer(:local), layer(:flag)]
    |> Enum.reduce(%{}, &deep_merge(&2, &1))
    |> deep_merge(get_all_session())
    |> harden_if_unparseable()
  end

  @doc "`get/2` resolved through `merged_trusted/0`."
  def get_trusted(key, default \\ nil) do
    case Map.fetch(merged_trusted(), to_string(key)) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  True when the current working directory has accepted workspace trust.

  Fails CLOSED (false — project-supplied config stays inert) on any Trust
  error so a crash can never widen the executable-config surface.
  """
  @spec project_trusted?() :: boolean()
  def project_trusted? do
    OptimalSystemAgent.Workspace.Trust.trusted?(OptimalSystemAgent.Workspace.Cwd.get())
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # A silently ignored config file is its own bug: say plainly that the rules
  # exist and are being WITHHELD pending trust, not that they are broken.
  # Once per {cwd, mtime} so it is visible without spamming every tool call.
  defp warn_project_withheld do
    path = project_settings_path()
    key = {:project_settings_withheld, path, file_sig(path)}

    if :ets.insert_new(@cache_table, {key, :withheld, true}) do
      Logger.warning(
        "[settings] WITHHOLDING project settings in #{path} (permission rules, permission_mode, " <>
          "env) — this workspace has not been trusted yet. They are ignored, not broken: run " <>
          "`/trust accept` (or accept the trust dialog) to apply them."
      )
    end

    %{}
  rescue
    _ -> %{}
  end

  @doc "Get settings from a specific layer."
  def layer(:user), do: load_json(user_settings())
  def layer(:project), do: load_json(project_settings_path())
  def layer(:local), do: load_json(local_settings_path())
  def layer(:session), do: get_all_session()

  def layer(:flag) do
    case flag_settings_path() do
      nil -> %{}
      path -> load_json(path)
    end
  end

  @doc """
  Merge `"hooks"` config across ALL settings layers by CONCATENATION.

  Unlike `get(:hooks)` (which returns only the highest-priority layer's map,
  shadowing every other source), this concatenates each event's hook list
  across user → project → local → session so hooks configured in multiple
  files all fire. Duplicate hook entries are removed.
  """
  def get_merged_hooks do
    # Workspace trust (CC parity, WS15 enforcement): checked-in project
    # settings are workspace-supplied executable config — their hooks stay
    # inert until the user accepts trust for the cwd (/trust accept or the
    # trust dialog). User/local/flag/session layers are authored on this
    # machine and always apply.
    project_layers = if project_trusted?(), do: [layer(:project)], else: []

    ([layer(:user)] ++ project_layers ++ [layer(:local), layer(:flag), layer(:session)])
    |> Enum.map(&layer_hooks/1)
    |> Enum.reduce(%{}, fn hooks, acc ->
      Map.merge(acc, hooks, fn _event, a, b -> a ++ b end)
    end)
    |> Map.new(fn {event, list} -> {event, Enum.uniq(list)} end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  # The session layer, as seen by the CALLING process: daemon-wide `:global`
  # rows first, then rows scoped to this process's session id, which win.
  #
  # Two concurrent sessions therefore see different session layers even though
  # they share one ETS table and one OS process — which is what makes
  # per-session tool policy expressible at all.
  defp get_all_session do
    try do
      global = session_rows({{:session, :"$1"}, :"$2"})

      case current_session() do
        :global -> global
        sid -> Map.merge(global, session_rows({{:session, sid, :"$1"}, :"$2"}))
      end
    rescue
      _ -> %{}
    end
  end

  defp session_rows(pattern) do
    :ets.match(:osa_settings, pattern)
    |> Enum.reduce(%{}, fn [key, value], acc -> Map.put(acc, to_string(key), value) end)
  end

  defp layer_hooks(layer) when is_map(layer) do
    case Map.get(layer, "hooks") do
      hooks when is_map(hooks) ->
        Map.new(hooks, fn {event, list} -> {to_string(event), List.wrap(list)} end)

      _ ->
        %{}
    end
  end

  defp layer_hooks(_), do: %{}

  # Presence-aware read for WRITE paths: distinguishes a missing/empty file
  # (fresh start → {:ok, %{}}) from an existing-but-unparseable one (refuse
  # to clobber → {:error, :corrupt}). Non-map top-level JSON is also corrupt.
  defp load_json_for_write(path) do
    case File.read(path) do
      {:ok, content} ->
        # BOM-tolerant on the WRITE path too: a BOM'd-but-valid file is not
        # corrupt, and refusing to write to it would strand the user.
        content = Bom.strip(content)

        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            {:ok, map}

          _ ->
            if String.trim(content) == "", do: {:ok, %{}}, else: {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} ->
        {:error, :corrupt}
    end
  end

  defp project_settings_path do
    Path.join(OptimalSystemAgent.Workspace.Cwd.get(), ".osa/settings.json")
  rescue
    _ -> ".osa/settings.json"
  end

  defp local_settings_path do
    Path.join(OptimalSystemAgent.Workspace.Cwd.get(), ".osa/settings.local.json")
  rescue
    _ -> ".osa/settings.local.json"
  end

  defp flag_settings_path do
    Application.get_env(:optimal_system_agent, :settings_flag_path) ||
      System.get_env("OSA_SETTINGS")
  end

  # Cached file read: `{path, sig, map}` rows in @cache_table, where sig is
  # `{mtime, size}`. A stat is much cheaper than read+decode; reset_cache/0
  # (watcher / internal writes) clears every row at once.
  defp load_json(path) do
    case file_sig(path) do
      nil -> %{}
      sig -> cached_parse(path, sig)
    end
  rescue
    _ -> %{}
  end

  defp file_sig(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _ -> nil
    end
  end

  defp cached_parse(path, sig) do
    case :ets.lookup(@cache_table, path) do
      [{^path, ^sig, map}] -> map
      _ -> parse_and_cache(path, sig)
    end
  rescue
    # Cache table not created yet (early boot) — read uncached.
    _ -> parse_json_file(path)
  end

  defp parse_and_cache(path, sig) do
    map = parse_json_file(path)

    try do
      :ets.insert(@cache_table, {path, sig, map})
    rescue
      _ -> :ok
    end

    map
  end

  # A settings file that EXISTS but cannot be parsed must not read as "no
  # settings". Returning `%{}` dropped the user's `permissions.deny` rules and
  # their chosen `permission_mode` silently, leaving the agent MORE permissive
  # than configured — a fail-OPEN on a security control.
  #
  # Two changes:
  #   1. The BOM is stripped first, so the overwhelmingly common cause (a
  #      Windows editor / PowerShell redirect writing `EF BB BF`) simply parses.
  #   2. What is still unparseable yields @unparseable_layer, which carries a
  #      marker key. `merged/0` and `merged_trusted/0` see the marker and pin
  #      `permission_mode` to "ask" — the deny rules cannot be recovered, but
  #      nothing runs unprompted while they are missing. And it is LOUD.
  @unparseable_key "__unparseable_settings__"

  defp parse_json_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case content |> Bom.strip() |> Jason.decode() do
          {:ok, map} when is_map(map) ->
            map

          _ ->
            if String.trim(Bom.strip(content)) == "" do
              %{}
            else
              warn_unparseable(path)
              %{@unparseable_key => [path]}
            end
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        warn_unreadable(path, reason)
        %{@unparseable_key => [path]}
    end
  end

  @doc """
  Paths of settings files that exist but could not be parsed, from the merged
  cascade. Empty list when every layer parsed (or was absent).
  """
  @spec unparseable_sources() :: [String.t()]
  def unparseable_sources do
    merged() |> Map.get(@unparseable_key, []) |> List.wrap()
  end

  # Fail CLOSED: while any settings layer is unreadable we cannot know what the
  # user denied, so nothing is auto-approved. "ask" is the most restrictive
  # mode that still lets work proceed (unlike "plan", which blocks all writes).
  defp harden_if_unparseable(%{@unparseable_key => [_ | _]} = merged) do
    Map.put(merged, "permission_mode", "ask")
  end

  defp harden_if_unparseable(merged), do: merged

  defp warn_unparseable(path) do
    once({:unparseable, path}, fn ->
      Logger.error(
        "[settings] #{path} exists but is NOT valid JSON — it is being IGNORED. " <>
          "Any `permissions` (allow/deny/ask), `permission_mode`, `env` and `hooks` in it " <>
          "are NOT in effect. permission_mode is forced to \"ask\" until this parses, so " <>
          "nothing runs unprompted while your rules are missing. Fix the JSON syntax."
      )
    end)
  end

  defp warn_unreadable(path, reason) do
    once({:unreadable, path}, fn ->
      Logger.error(
        "[settings] #{path} cannot be read (#{inspect(reason)}) — its permission rules and " <>
          "permission_mode are NOT in effect. permission_mode is forced to \"ask\"."
      )
    end)
  end

  # Log once per {kind, path, file signature} so a broken file is visible
  # without a line per tool call, but re-announces after every edit attempt.
  defp once(key, fun) do
    {kind, path} = key

    if :ets.insert_new(@cache_table, {{kind, path, file_sig(path)}, :warned, true}) do
      fun.()
    end

    :ok
  rescue
    _ ->
      fun.()
      :ok
  end

  defp write_json(path, data) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    AtomicFile.write!(path, Jason.encode!(data, pretty: true))
    :ok
  rescue
    e ->
      Logger.warning("[settings] Failed to write #{path}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
