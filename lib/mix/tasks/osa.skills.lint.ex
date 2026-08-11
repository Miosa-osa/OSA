defmodule Mix.Tasks.Osa.Skills.Lint do
  @shortdoc "Validate every discoverable SKILL.md and report authoring errors"

  @moduledoc """
  Lint the agent's `SKILL.md` files.

  Skill discovery is deliberately forgiving: a file with a typo'd or missing
  frontmatter header still loads — silently misnamed, with its first 100 raw
  bytes as the description, so it is mis-ranked and effectively never surfaces.
  This task is the feedback that forgiveness removes.

      mix osa.skills.lint                 # scan local/repo/user scopes + bundled
      mix osa.skills.lint priv/skills     # scan explicit roots
      mix osa.skills.lint --no-bundled    # skip the application's priv/skills
      mix osa.skills.lint --strict        # treat warnings as failures too

  Exits `1` when any `:error` finding is reported (or any finding at all under
  `--strict`), so it can gate CI.
  """

  use Mix.Task

  alias OptimalSystemAgent.Skills.Lint

  @impl Mix.Task
  def run(argv) do
    {opts, roots, _} =
      OptionParser.parse(argv, strict: [bundled: :boolean, strict: :boolean])

    Mix.Task.run("app.config")

    report =
      Lint.run(
        roots: Enum.map(roots, &Path.expand/1),
        include_bundled: Keyword.get(opts, :bundled, true)
      )

    Mix.shell().info(Lint.format(report))

    fail? =
      if Keyword.get(opts, :strict, false) do
        report.errors > 0 or report.warnings > 0
      else
        report.errors > 0
      end

    if fail?, do: exit({:shutdown, 1}), else: :ok
  end
end
