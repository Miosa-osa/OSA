defmodule OptimalSystemAgent.Tools.Registry.SkillLoader do
  @moduledoc """
  Loads and parses SKILL.md skill definitions with **progressive disclosure**.

  A skill *is* a `SKILL.md` file: YAML frontmatter + a markdown instruction
  body. Discovery reads the **frontmatter only** (bounded to the first
  `#{4096}` bytes) to build the listing — the body is never loaded for a
  listing. The body is loaded on demand via `load_body/1` /
  `load_skill_with_body/1` when a skill is actually invoked.

  ## Scopes and precedence (lower wins)

  Skills are discovered across several scopes, Claude-compatible. For a given
  skill name, the entry from the lowest-ranked scope wins:

    * `:local`   (rank 0) — `<cwd>/{.osa,.claude,.agents,.grok}/skills`
    * `:repo`    (rank 1) — the same dirs at any ancestor up to the git root
    * `:user`    (rank 2) — the configured `:skills_dir` (default `~/.osa/skills`)
      plus `~/{.claude,.agents,.grok}/skills`
    * `:bundled` (rank 3) — the application's `priv/skills` tree

  Vendor directories (`node_modules`, `.git`, `_build`, `deps`, …) are skipped.

  ## `paths`-glob lazy surfacing

  A skill may declare `paths:` globs in its frontmatter. Such a skill is held
  back from the model-facing listing until a file matching one of the globs is
  touched this session (see `SkillTouch` and `list_for_model/2`).
  """

  require Logger

  alias OptimalSystemAgent.Skills.Frontmatter
  alias OptimalSystemAgent.Tools.Registry.SkillTouch

  @frontmatter_max_bytes 4_096

  @known_skill_categories ~w(core automation reasoning)

  # Config directory names scanned for a `skills/` subtree (Claude-compatible).
  @external_cfg_dirs ~w(.osa .claude .agents .codex .grok)
  # User-scope config dirs other than .osa (whose skills dir is :skills_dir).
  @user_ext_dirs ~w(.claude .agents .codex .grok)
  @skills_subdir "skills"

  # Path segments that must never be scanned for skills.
  @vendor_denylist ~w(node_modules .git _build deps vendor target dist build .elixir_ls .venv)

  @scope_rank %{local: 0, repo: 1, user: 2, bundled: 3}

  defp skills_dir, do: Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Load all skills across scopes as a `name => entry` map (frontmatter only).

  Each entry is a map with `:name`, `:description`, `:triggers`, `:tools`,
  `:priority`, `:paths` (globs or `nil`), `:scope`, and `:path` (absolute
  SKILL.md path). The instruction body is **not** included — load it on demand
  with `load_body/1` or `load_skill_with_body/1`.

  Options:
    * `:cwd` — override the current working directory used for local/repo scopes.
  """
  @spec load_skills(keyword()) :: %{optional(String.t()) => map()}
  def load_skills(opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || cwd_default()

    cwd
    |> discover_entries()
    |> merge_by_scope()
  end

  @doc """
  Frontmatter-only listing intended for the model-facing surface.

  Applies `paths`-glob lazy surfacing: a skill with `:paths` globs is only
  included once one of `touched_paths` matches. Skills without `:paths` are
  always included. Returns a name-sorted list of entry maps.
  """
  @spec list_for_model(%{optional(String.t()) => map()} | [map()], [String.t()]) :: [map()]
  def list_for_model(skills, touched_paths \\ [])

  def list_for_model(skills, touched_paths) when is_map(skills) do
    skills |> Map.values() |> list_for_model(touched_paths)
  end

  def list_for_model(skills, touched_paths) when is_list(skills) do
    skills
    |> Enum.filter(&surfaced?(&1, touched_paths))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Whether a skill entry should surface, given the paths touched this session.

  Always true when the skill declares no `:paths` globs; otherwise true only
  when a touched path matches one of the globs.
  """
  @spec surfaced?(map(), [String.t()]) :: boolean()
  def surfaced?(%{paths: paths}, touched_paths)
      when is_list(paths) and paths != [] and is_list(touched_paths) do
    Enum.any?(touched_paths, fn p ->
      Enum.any?(paths, fn glob -> path_matches_glob?(p, glob) end)
    end)
  end

  def surfaced?(_entry, _touched), do: true

  @doc """
  Canonical "is this skill switched off?" check — the ONE definition.

  The marker is a `.disabled` file **next to the skill's own SKILL.md**, so it
  works for every skill discovery can see: nested under a category directory,
  named differently from its directory, or living in any scope (local, repo,
  user, bundled).

  Callers used to compute `<skills_dir>/<frontmatter-name>/.disabled` instead —
  a flat path in ONE root. That made every bundled `priv/skills` skill and
  every project-scoped `.claude/skills` skill undisableable by construction,
  and it disagreed with `osa doctor`, which already used the path below.
  """
  @spec disabled?(map() | String.t() | nil) :: boolean()
  def disabled?(%{path: path}), do: disabled?(path)
  def disabled?(entry) when is_map(entry), do: disabled?(Map.get(entry, "path"))

  def disabled?(path) when is_binary(path) and path != "" do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)
    File.exists?(Path.join(dir, ".disabled"))
  rescue
    _ -> false
  end

  def disabled?(_), do: false

  @doc """
  Drop every disabled skill from a list or `name => entry` map.

  Returns the same shape it was given.
  """
  @spec reject_disabled(%{optional(String.t()) => map()} | [map()]) ::
          %{optional(String.t()) => map()} | [map()]
  def reject_disabled(skills) when is_map(skills) do
    skills |> Enum.reject(fn {_name, entry} -> disabled?(entry) end) |> Map.new()
  end

  def reject_disabled(skills) when is_list(skills), do: Enum.reject(skills, &disabled?/1)

  @doc """
  Absolute roots skills are discovered from, for the given cwd.

  Exposed so invoke-time containment checks test against the SAME set of
  directories discovery used, rather than re-hardcoding one of them.
  """
  @spec roots(String.t() | nil) :: [String.t()]
  def roots(cwd \\ nil) do
    (cwd || cwd_default())
    |> scope_roots()
    |> dedupe_roots()
    |> Enum.map(fn {_scope, path} -> path end)
  end

  @doc """
  True when `path` lies inside one of the skill discovery roots.

  Compares on path BOUNDARIES: a plain `String.starts_with?` would accept
  `~/.osa/skills-backup/evil/SKILL.md` for the root `~/.osa/skills`.
  """
  @spec within_roots?(String.t(), String.t() | nil) :: boolean()
  def within_roots?(path, cwd \\ nil) when is_binary(path) do
    expanded = Path.expand(path)

    Enum.any?(roots(cwd), fn root ->
      root = Path.expand(root)
      expanded == root or String.starts_with?(expanded, root <> "/")
    end)
  rescue
    _ -> false
  end

  @doc "Match a path against a gitignore-style glob (`**`, `*`, `?`)."
  @spec path_matches_glob?(String.t(), String.t()) :: boolean()
  def path_matches_glob?(path, glob) when is_binary(path) and is_binary(glob) do
    regex = glob_to_regex(glob)
    Regex.match?(regex, path) or Regex.match?(regex, Path.basename(path))
  rescue
    _ -> false
  end

  def path_matches_glob?(_, _), do: false

  @doc """
  Load only the instruction body of a SKILL.md (frontmatter stripped).

  This is the on-demand half of progressive disclosure.
  """
  @spec load_body(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def load_body(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, extract_body(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_body(_), do: {:error, :no_path}

  @doc """
  Return a skill entry augmented with its instruction body under `:instructions`.

  Accepts a listing entry (must carry `:path`). Loads the full file on demand.
  """
  @spec load_skill_with_body(map()) :: {:ok, map()} | {:error, term()}
  def load_skill_with_body(%{path: path} = entry) when is_binary(path) do
    case load_body(path) do
      {:ok, body} -> {:ok, Map.put(entry, :instructions, body)}
      {:error, _} = err -> err
    end
  end

  def load_skill_with_body(_), do: {:error, :no_path}

  @doc """
  Discover skill definitions from `priv/skills/` (bundled), frontmatter only.

  Returns a list of maps with `:name`, `:description`, `:category`,
  `:triggers`, `:priority`, `:tools`, `:source_path`, `:metadata`. Kept for
  callers that only want the bundled catalog summary (e.g. HTTP routes); does
  not include instruction bodies.
  """
  @spec load_skill_definitions() :: [map()]
  def load_skill_definitions do
    skills_path = resolve_priv_skills_path()

    if skills_path && File.dir?(skills_path) do
      skills_path
      |> find_md_files()
      |> Enum.reject(&vendor_below_root?(&1, skills_path))
      |> Enum.flat_map(fn path -> definition_summary(path, skills_path) end)
    else
      []
    end
  end

  # ── Discovery (frontmatter only) ──────────────────────────────────────

  defp discover_entries(cwd) do
    cwd
    |> scope_roots()
    |> dedupe_roots()
    |> Enum.flat_map(fn {scope, root} -> scan_root(scope, root) end)
  end

  defp scan_root(scope, root) do
    if File.dir?(root) do
      # Parallelize the per-file frontmatter reads: each is an independent,
      # I/O-bound File.read (4KB) + YAML parse, and there can be dozens of
      # SKILL.md files across scopes. Sequentially this was ~380ms at boot (the
      # bulk of Tools.Registry init); fanning the reads across schedulers cuts
      # the wall-clock to the slowest single file. Order does not matter —
      # merge_by_scope/sort run downstream.
      root
      |> Path.join("**/SKILL.md")
      |> Path.wildcard()
      |> Enum.reject(&vendor_below_root?(&1, root))
      |> Task.async_stream(
        fn path -> read_frontmatter_entry(path, scope) end,
        max_concurrency: max(System.schedulers_online(), 2),
        ordered: false,
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, entry}} -> [entry]
        _ -> []
      end)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[skill_loader] Failed to scan #{root}: #{Exception.message(e)}")
      []
  end

  # Later collision losers keep the lower-ranked scope's entry.
  defp merge_by_scope(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      case Map.get(acc, entry.name) do
        nil ->
          Map.put(acc, entry.name, entry)

        current ->
          if rank(entry.scope) < rank(current.scope) do
            Map.put(acc, entry.name, entry)
          else
            acc
          end
      end
    end)
  end

  # Every root — project, user and bundled alike — goes through the ONE
  # workspace-trust boundary (`Workspace.ProjectResource`), which classifies by
  # where the directory actually lives rather than by the `:local`/`:repo`/
  # `:user`/`:bundled` label this function attaches. A checked-out repo's
  # `.osa/skills/<name>/SKILL.md` outranks the bundled skill of the same name
  # (`@scope_rank`: local 0 < bundled 3), so an untrusted clone could REPLACE a
  # bundled skill's instructions — the body becomes a subagent's whole
  # `system_prompt` in `UseSkill` — and inject its own entries into the
  # model-facing listing. Withheld until the workspace is trusted.
  defp scope_roots(cwd) do
    project = project_roots(cwd)

    user =
      [{:user, Path.expand(skills_dir())}] ++
        Enum.map(@user_ext_dirs, fn ext -> {:user, Path.expand("~/#{ext}/#{@skills_subdir}")} end)

    bundled =
      case resolve_priv_skills_path() do
        nil -> []
        path -> [{:bundled, path}]
      end

    OptimalSystemAgent.Workspace.ProjectResource.admit(project ++ user ++ bundled, :skills,
      cwd: cwd,
      why:
        "A SKILL.md body becomes a subagent's entire system prompt, and a project skill " <>
          "outranks the bundled skill of the same name, so it can replace trusted instructions."
    )
  end

  defp project_roots(cwd) do
    cwd
    |> ancestor_dirs()
    |> Enum.with_index()
    |> Enum.flat_map(fn {dir, idx} ->
      scope = if idx == 0, do: :local, else: :repo
      Enum.map(@external_cfg_dirs, fn ext -> {scope, Path.join([dir, ext, @skills_subdir])} end)
    end)
  end

  # cwd first (nearest), then ancestors up to and including the git root. Bounded.
  defp ancestor_dirs(cwd) do
    collect_up(Path.expand(cwd), [])
  end

  defp collect_up(dir, acc) do
    acc = acc ++ [dir]
    parent = Path.dirname(dir)

    cond do
      File.dir?(Path.join(dir, ".git")) -> acc
      parent == dir -> acc
      length(acc) >= 25 -> acc
      true -> collect_up(parent, acc)
    end
  end

  # Collapse identical absolute roots, keeping the lowest-ranked scope.
  defp dedupe_roots(roots) do
    roots
    |> Enum.reduce(%{}, fn {scope, path}, acc ->
      abs = Path.expand(path)

      case Map.get(acc, abs) do
        nil ->
          Map.put(acc, abs, scope)

        existing ->
          if rank(scope) < rank(existing), do: Map.put(acc, abs, scope), else: acc
      end
    end)
    |> Enum.map(fn {abs, scope} -> {scope, abs} end)
  end

  defp rank(scope), do: Map.get(@scope_rank, scope, 99)

  # Reject a skill file only when a vendor directory appears *below* the scan
  # root. The root's own prefix is exempt: the bundled scope legitimately lives
  # under `_build`/`deps` (dev) or a release lib dir, and must not self-exclude.
  defp vendor_below_root?(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.any?(&(&1 in @vendor_denylist))
  end

  # ── Frontmatter parsing (bounded) ─────────────────────────────────────

  defp read_frontmatter_entry(path, scope) do
    data = bounded_read(path, @frontmatter_max_bytes)

    case parse_frontmatter(data) do
      {:ok, meta} -> {:ok, build_entry(meta, path, scope)}
      :error -> {:ok, fallback_entry(path, scope, data)}
    end
  rescue
    e ->
      Logger.warning("[skill_loader] Skipping unreadable skill #{path}: #{Exception.message(e)}")
      :error
  end

  # Read at most `n` bytes without slurping the whole (possibly large) body.
  defp bounded_read(path, n) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        data =
          case IO.binread(io, n) do
            bin when is_binary(bin) -> bin
            _ -> ""
          end

        File.close(io)
        data

      {:error, _} ->
        ""
    end
  end

  # Parse only the frontmatter block. If the closing `---` is not within the
  # bounded window (or YAML is invalid) return :error so the caller falls back.
  # Delegates to the ONE frontmatter parser so BOM tolerance is not re-derived.
  defp parse_frontmatter(data) do
    case Frontmatter.parse(data) do
      {:ok, meta, _body} -> {:ok, meta}
      {:error, _reason} -> :error
    end
  end

  defp build_entry(meta, path, scope) do
    name =
      meta["name"] || meta["skill_name"] || meta["skill"] ||
        Path.basename(Path.dirname(path))

    %{
      name: to_string(name),
      description: to_string(meta["description"] || ""),
      triggers: normalize_triggers(meta),
      tools: normalize_tools(meta["tools"]),
      priority: parse_priority_meta(meta["priority"]),
      paths: normalize_paths(meta["paths"]),
      scope: scope,
      path: path
    }
  end

  defp fallback_entry(path, scope, data) do
    %{
      name: Path.basename(Path.dirname(path)),
      description: data |> String.slice(0, 100) |> String.trim(),
      triggers: [],
      tools: [],
      priority: 5,
      paths: nil,
      scope: scope,
      path: path
    }
  end

  # Strip YAML frontmatter, returning only the instruction body.
  defp extract_body(content), do: Frontmatter.body(content)

  # ── Bundled-catalog summaries (priv/skills) ───────────────────────────

  defp definition_summary(path, base_path) do
    relative_path = Path.relative_to(path, base_path)
    category = derive_category(relative_path)
    data = bounded_read(path, @frontmatter_max_bytes)

    case parse_frontmatter(data) do
      {:ok, meta} ->
        name =
          meta["name"] || meta["skill_name"] || meta["skill"] ||
            derive_name_from_path(relative_path)

        standard_keys =
          ~w(name skill_name skill description trigger triggers trigger_keywords priority tools paths)

        [
          %{
            name: to_string(name),
            description: to_string(meta["description"] || ""),
            category: category,
            triggers: normalize_triggers(meta),
            priority: parse_priority_meta(meta["priority"]),
            tools: normalize_tools(meta["tools"]),
            source_path: relative_path,
            metadata: Map.drop(meta, standard_keys)
          }
        ]

      :error ->
        [
          %{
            name: derive_name_from_path(relative_path),
            description: data |> String.slice(0, 100) |> String.trim(),
            category: category,
            triggers: [],
            priority: 5,
            tools: [],
            source_path: relative_path,
            metadata: %{}
          }
        ]
    end
  rescue
    e ->
      Logger.warning("[skill_loader] Failed to summarize #{path}: #{Exception.message(e)}")
      []
  end

  # ── Normalizers ───────────────────────────────────────────────────────

  # A skill's declared tool allowlist may be a YAML list or a comma-separated
  # string. Normalize to a list of tool-name strings ([] = unrestricted).
  defp normalize_tools(nil), do: []
  defp normalize_tools(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp normalize_tools(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_tools(_), do: []

  # `paths` frontmatter: a YAML list or comma-separated string of globs.
  # Returns nil (never gated) when absent or empty.
  defp normalize_paths(nil), do: nil

  defp normalize_paths(list) when is_list(list) do
    case list |> List.flatten() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      globs -> globs
    end
  end

  defp normalize_paths(str) when is_binary(str) do
    case str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      globs -> globs
    end
  end

  defp normalize_paths(_), do: nil

  defp normalize_triggers(meta) do
    cond do
      is_list(meta["triggers"]) ->
        meta["triggers"] |> List.flatten() |> Enum.map(&to_string/1)

      is_list(meta["trigger_keywords"]) ->
        meta["trigger_keywords"] |> List.flatten() |> Enum.map(&to_string/1)

      is_binary(meta["trigger"]) ->
        meta["trigger"]
        |> String.split(~r/[|,]/, trim: true)
        |> Enum.map(&String.trim/1)

      true ->
        []
    end
  end

  defp parse_priority_meta(p) when is_integer(p), do: p
  defp parse_priority_meta(p) when is_binary(p), do: parse_priority(p)
  defp parse_priority_meta(_), do: 5

  defp parse_priority(str) do
    case Integer.parse(str) do
      {n, ""} ->
        n

      _ ->
        case String.downcase(String.trim(str)) do
          "critical" -> 0
          "high" -> 1
          "medium" -> 3
          "low" -> 7
          _ -> 5
        end
    end
  end

  # ── Glob → Regex (gitignore-ish) ──────────────────────────────────────

  defp glob_to_regex(glob) do
    body = translate_glob(String.graphemes(glob), [])
    Regex.compile!("(?:^|/)" <> body <> "$")
  end

  defp translate_glob([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp translate_glob(["*", "*" | rest], acc), do: translate_glob(rest, [".*" | acc])
  defp translate_glob(["*" | rest], acc), do: translate_glob(rest, ["[^/]*" | acc])
  defp translate_glob(["?" | rest], acc), do: translate_glob(rest, ["[^/]" | acc])
  defp translate_glob([c | rest], acc), do: translate_glob(rest, [Regex.escape(c) | acc])

  # ── Paths / categories ────────────────────────────────────────────────

  defp derive_category(relative_path) do
    case Path.split(relative_path) do
      [dir, _file] when dir in @known_skill_categories -> dir
      [_dir, "SKILL.md"] -> "standalone"
      _ -> "standalone"
    end
  end

  defp derive_name_from_path(relative_path) do
    filename = Path.basename(relative_path, ".md")

    if filename == "SKILL" do
      relative_path |> Path.dirname() |> Path.basename()
    else
      filename
    end
  end

  defp find_md_files(dir), do: Path.wildcard(Path.join(dir, "**/*.md"))

  defp cwd_default do
    OptimalSystemAgent.Workspace.Cwd.get()
  rescue
    _ -> File.cwd!()
  catch
    _, _ -> File.cwd!()
  end

  defp resolve_priv_skills_path do
    case :code.priv_dir(:optimal_system_agent) do
      {:error, _} ->
        app_dir = Application.app_dir(:optimal_system_agent)

        if app_dir do
          Path.join(app_dir, "priv/skills")
        else
          Path.join([File.cwd!(), "priv", "skills"])
        end

      priv_dir ->
        Path.join(to_string(priv_dir), "skills")
    end
  rescue
    _ -> Path.join([File.cwd!(), "priv", "skills"])
  end

  # ── Convenience: touched-path helpers (delegate to SkillTouch) ─────────

  @doc "Record a touched path for `paths`-glob lazy surfacing (delegates to SkillTouch)."
  @spec record_touch(term(), String.t()) :: :ok
  defdelegate record_touch(session_id, path), to: SkillTouch, as: :record

  @doc "List paths touched this session (delegates to SkillTouch)."
  @spec touched_paths(term()) :: [String.t()]
  defdelegate touched_paths(session_id), to: SkillTouch, as: :list
end
