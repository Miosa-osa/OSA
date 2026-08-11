defmodule OptimalSystemAgent.Skills.Lint do
  @moduledoc """
  Author-facing lint over every discoverable `SKILL.md`.

  Discovery is deliberately forgiving (see `Skills.Validator`) — a malformed
  skill still loads, just wrong and silently. This module is the deliberate,
  runnable counterpart: it walks the same scopes `Tools.Registry.SkillLoader`
  walks, validates each file, and reports what is broken *and how to fix it*.

  Two entry points:

    * `run/1` — programmatic; returns `{findings, scanned_paths}`.
    * `mix osa.skills.lint` — the author/CI surface. Exits non-zero when any
      finding is an `:error`, which is what makes the authoring standard
      enforceable in CI rather than advisory.

  Scanning is by PATH, not by loaded entry: cross-scope precedence means a
  malformed skill can be shadowed by a well-formed one of the same name and
  never appear in the loaded map, while still being broken on disk.
  """

  alias OptimalSystemAgent.Skills.Validator
  alias OptimalSystemAgent.Tools.Registry.SkillLoader

  # Same config-dir names the loader scans.
  @cfg_dirs ~w(.osa .claude .agents .grok)
  @skills_subdir "skills"
  @vendor_denylist ~w(node_modules .git _build deps vendor target dist build .elixir_ls .venv)

  @type report :: %{
          findings: [Validator.finding()],
          scanned: [String.t()],
          errors: non_neg_integer(),
          warnings: non_neg_integer()
        }

  @doc """
  Lint every discoverable `SKILL.md`.

  Options:
    * `:cwd`     — working directory for the local/repo scopes (default: `File.cwd!/0`)
    * `:roots`   — explicit list of directories to scan INSTEAD of scope discovery
    * `:include_bundled` — also lint the application's `priv/skills` tree (default `true`)
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    paths = opts |> scan_paths() |> Enum.uniq() |> Enum.sort()

    findings = Enum.flat_map(paths, &Validator.validate_file/1)

    %{
      findings: findings,
      scanned: paths,
      errors: Enum.count(findings, &(&1.severity == :error)),
      warnings: Enum.count(findings, &(&1.severity == :warning))
    }
  end

  @doc """
  Render a `t:report/0` as an author-facing block, ending in a one-line verdict.
  """
  @spec format(report()) :: String.t()
  def format(%{findings: [], scanned: scanned}) do
    "skills lint: #{length(scanned)} SKILL.md file(s) scanned, no issues."
  end

  def format(%{findings: findings, scanned: scanned, errors: errors, warnings: warnings}) do
    Validator.format(findings) <>
      "\n\nskills lint: #{length(scanned)} SKILL.md file(s) scanned — " <>
      "#{errors} error(s), #{warnings} warning(s)."
  end

  # ── Path discovery ───────────────────────────────────────────────────────

  defp scan_paths(opts) do
    case Keyword.get(opts, :roots) do
      roots when is_list(roots) and roots != [] ->
        Enum.flat_map(roots, &skill_files/1)

      _ ->
        cwd = Keyword.get(opts, :cwd) || File.cwd!()

        project_and_user_roots(cwd)
        |> Enum.flat_map(&skill_files/1)
        |> Kernel.++(bundled_files(Keyword.get(opts, :include_bundled, true)))
    end
  end

  defp project_and_user_roots(cwd) do
    project =
      cwd
      |> ancestor_dirs()
      |> Enum.flat_map(fn dir ->
        Enum.map(@cfg_dirs, &Path.join([dir, &1, @skills_subdir]))
      end)

    user =
      [Path.expand(configured_skills_dir())] ++
        Enum.map(@cfg_dirs, &Path.expand("~/#{&1}/#{@skills_subdir}"))

    Enum.map(project ++ user, &Path.expand/1)
  end

  defp configured_skills_dir,
    do: Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")

  # cwd first, then ancestors up to and including the git root (bounded), mirroring
  # SkillLoader.collect_up/2.
  defp ancestor_dirs(cwd), do: collect_up(Path.expand(cwd), [])

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

  defp bundled_files(false), do: []

  defp bundled_files(true) do
    case SkillLoader.load_skills() do
      skills when is_map(skills) ->
        skills
        |> Map.values()
        |> Enum.filter(&(Map.get(&1, :scope) == :bundled))
        |> Enum.map(& &1.path)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp skill_files(root) do
    if File.dir?(root) do
      root
      |> Path.join("**/SKILL.md")
      |> Path.wildcard()
      |> Enum.reject(&vendor?(&1, root))
    else
      []
    end
  rescue
    _ -> []
  end

  defp vendor?(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.any?(&(&1 in @vendor_denylist))
  end
end
