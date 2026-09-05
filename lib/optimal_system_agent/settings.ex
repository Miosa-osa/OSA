defmodule OptimalSystemAgent.Settings do
  @moduledoc """
  Multi-layer settings cascade.

  Settings are resolved through 4 layers (highest priority last):

  1. **User** — `~/.osa/settings.json` (global user preferences)
  2. **Project** — `.osa/settings.json` (checked into repo, shared with team)
  3. **Local** — `.osa/settings.local.json` (conventionally gitignored, per-developer)
  4. **Flag** — file named by `--settings <file>` / `OSA_SETTINGS` (optional)
  5. **Session** — in-memory only, set via API or CLI commands

  ## Which layers are workspace-supplied

  Layers 2 and 3 both resolve against `Workspace.Cwd.get/0`, so both ship
  inside whatever repository happens to be the cwd. Security-relevant keys
  from either are gated behind workspace trust — see `trusted_layer/1`.
  "Conventionally gitignored" is not a security property: `.gitignore` is
  advisory, and the author of a hostile repo can commit the file regardless.

  Layers 1, 4 and 5 are authored on this machine by the operator and always
  apply. Layer 4 (`OSA_SETTINGS`) is therefore the supported way for headless
  and benchmark runs to impose policy without any workspace trust.

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

  # Marker key injected by `parse_json_file/1` for a file that exists but
  # cannot be parsed. Declared here (not next to its writer) because
  # `trusted_layer/1` above must reference it, and attributes resolve in
  # source order. See `harden_if_unparseable/1` for the fail-closed behaviour.
  @unparseable_key "__unparseable_settings__"

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

  @doc "Get a setting using the session layer for a SPECIFIC session id."
  @spec get_session_for(String.t() | nil, atom() | String.t(), term()) :: term()
  def get_session_for(session_id, key, default \\ nil) do
    session =
      case session_id do
        sid when is_binary(sid) and sid != "" ->
          global = session_rows({{:session, :"$1"}, :"$2"})
          Map.merge(global, session_rows({{:session, sid, :"$1"}, :"$2"}))

        _ ->
          session_rows({{:session, :"$1"}, :"$2"})
      end

    case Map.fetch(session, to_string(key)) do
      {:ok, value} -> value
      :error -> default
    end
  rescue
    _ -> default
  end

  @doc """
  Remove ONE session-scoped setting, so the cascade resolves it again.

  Not the same as `set_session(key, nil)`, and the difference is the whole
  reason this exists. Resolution is presence-based (`Map.fetch` on the merged
  map — CC `updateSettingsForSource` semantics), so a written `nil` is an
  explicit "this setting is null" that SHADOWS every lower layer for as long as
  the row survives. Without a delete, "put the setting back the way it was"
  had no expression, and the nearest thing to hand — writing `nil` or `%{}` —
  quietly pinned the key instead of releasing it.

  Scoped exactly like `set_session/2`: the current session's row when one is
  published, the daemon-wide `:global` row otherwise.
  """
  @spec delete_session(atom() | String.t()) :: :ok
  def delete_session(key), do: drop_session(current_session(), key)

  @doc "`delete_session/1` for a SPECIFIC session id (`nil` → the `:global` scope)."
  @spec delete_session_for(String.t() | nil, atom() | String.t()) :: :ok
  def delete_session_for(session_id, key) when is_binary(session_id) and session_id != "",
    do: drop_session(session_id, key)

  def delete_session_for(_session_id, key), do: drop_session(:global, key)

  defp drop_session(:global, key) do
    # `put_session(:global, …)` stores the key VERBATIM (it is `get_all_session`
    # that stringifies on read), so `set_session(:effort_level, …)` leaves an
    # atom-keyed row and `set_session("effort_level", …)` a binary-keyed one.
    # Both spellings are dropped, or a delete written one way silently misses a
    # row written the other and reads as a no-op.
    Enum.each(global_key_spellings(key), &:ets.delete(:osa_settings, {:session, &1}))
    :ok
  rescue
    _ -> :ok
  end

  defp drop_session(session_id, key) do
    :ets.delete(:osa_settings, {:session, session_id, to_string(key)})
    :ok
  rescue
    _ -> :ok
  end

  defp global_key_spellings(key) when is_atom(key), do: [key, Atom.to_string(key)]

  defp global_key_spellings(key) when is_binary(key) do
    [key | try_existing_atom(key)]
  end

  defp global_key_spellings(key), do: [key, to_string(key)]

  defp try_existing_atom(key) do
    [String.to_existing_atom(key)]
  rescue
    ArgumentError -> []
  end

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
  Like `layer/1`, but every WORKSPACE-SUPPLIED layer is gated behind trust.

  The gate keys on **where the file lives**, not on what the layer is called:

    * `:project` — `<cwd>/.osa/settings.json`       — gated
    * `:local`   — `<cwd>/.osa/settings.local.json` — gated
    * `:user` / `:flag` / `:session`                — always apply

  Both gated files resolve through `Workspace.Cwd.get/0`, so they ship inside
  the repository. `:local` was originally exempt on the grounds that it is
  "gitignored, per-developer" — but `.gitignore` is advisory and the attacker
  authors the repo: `git add -f .osa/settings.local.json` commits it and a
  clone delivers it. That made the `:project` gate bypassable by renaming the
  hostile file, so `:local` is gated on exactly the same terms.

  `:user` (`~/.osa/settings.json`), `:flag` (`--settings` / `OSA_SETTINGS`) and
  `:session` are authored on this machine by the operator, never by the
  workspace, so they always apply. That is deliberately the automation path:
  headless and benchmark runs express policy through `OSA_SETTINGS`, which
  needs no workspace trust — the safe path is the default one, not the one that
  requires remembering a flag.

  Every security-relevant read of the cascade goes through here (and
  `get_trusted/2` / `merged_trusted/0`) rather than `layer/1`.
  """
  @spec trusted_layer(atom()) :: map()
  def trusted_layer(source) when source in [:project, :local] do
    if project_trusted?() do
      layer(source)
    else
      case layer(source) do
        empty when empty == %{} ->
          %{}

        # An unparseable workspace file is withheld like any other, but its
        # MARKER still propagates: `merged_trusted/0` must keep failing CLOSED
        # (permission_mode pinned to "ask") rather than reading a file it
        # cannot parse as "no restrictions" merely because the workspace is
        # untrusted. Withholding is not the same as absence.
        %{@unparseable_key => _} = marker ->
          Map.take(marker, [@unparseable_key])

        _ ->
          warn_workspace_withheld(source)
      end
    end
  end

  def trusted_layer(source), do: layer(source)

  @doc """
  `merged/0` with the project layer gated behind workspace trust.
  Use for any security-relevant setting; `merged/0` stays as-is for display.
  """
  def merged_trusted do
    [layer(:user), trusted_layer(:project), trusted_layer(:local), layer(:flag)]
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
    # Resolved through the shared boundary so there is exactly ONE fail-closed
    # definition of "is this workspace trusted" — see
    # `OptimalSystemAgent.Workspace.ProjectResource`.
    OptimalSystemAgent.Workspace.ProjectResource.trusted?()
  end

  # A silently ignored config file is its own bug: say plainly that the rules
  # exist and are being WITHHELD pending trust, not that they are broken.
  # Once per {cwd, mtime} so it is visible without spamming every tool call.
  defp warn_workspace_withheld(source) do
    path = if source == :local, do: local_settings_path(), else: project_settings_path()
    key = {:project_settings_withheld, path, file_sig(path)}

    if :ets.insert_new(@cache_table, {key, :withheld, true}) do
      Logger.warning(
        "[settings] WITHHOLDING workspace settings in #{path} (permission rules, permission_mode, " <>
          "env, hooks) — this workspace has not been trusted yet. They are ignored, not broken: " <>
          "run `/trust accept` (or accept the trust dialog) to apply them. Automation should " <>
          "express policy through OSA_SETTINGS / --settings, which needs no workspace trust."
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
    # Workspace trust (CC parity, WS15 enforcement): BOTH checked-in project
    # settings AND `.osa/settings.local.json` are workspace-supplied executable
    # config — a hook is a shell command. They stay inert until the user
    # accepts trust for the cwd (/trust accept or the trust dialog).
    # User/flag/session layers are authored on this machine and always apply.
    workspace_layers = if project_trusted?(), do: [layer(:project), layer(:local)], else: []

    ([layer(:user)] ++ workspace_layers ++ [layer(:flag), layer(:session)])
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
  #
  # (`@unparseable_key` itself is declared near the top of the module, because
  # `trusted_layer/1` references it and attributes resolve in source order.)

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
  #
  # BOTH spellings of the mode are pinned, and pinning only one is why this
  # existed without working. `Permissions.default_mode/0` reads the CC key
  # `permissions.defaultMode` FIRST and only falls back to the legacy
  # top-level `permission_mode`; this function used to pin the fallback alone.
  # So the rule fired for legacy settings and was completely inert for the CC
  # key that supersedes it: with a corrupt layer in the cascade, a
  # `"defaultMode": "bypassPermissions"` user carried on auto-approving every
  # tool call while the `deny` list that was supposed to bound them had
  # vanished — the exact fail-OPEN this function exists to prevent, reached by
  # the newer of the two documented spellings.
  #
  # "default" is the CC vocabulary for ask (`Permissions.@default_mode_map`),
  # and it is written even when the user set no `permissions` block at all, so
  # the pin does not depend on which keys the surviving layers happen to have.
  defp harden_if_unparseable(%{@unparseable_key => [_ | _]} = merged) do
    permissions =
      case Map.get(merged, "permissions") do
        m when is_map(m) -> m
        _ -> %{}
      end

    merged
    |> Map.put("permission_mode", "ask")
    |> Map.put("permissions", Map.put(permissions, "defaultMode", "default"))
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
