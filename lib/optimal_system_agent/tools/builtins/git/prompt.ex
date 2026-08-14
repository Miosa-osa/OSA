defmodule OptimalSystemAgent.Tools.Builtins.Git.Prompt do
  @moduledoc """
  Dynamic prompt for the `git` tool.

  Encodes the Git Safety Protocol drawn from the the prior generation flow
  analysis (docs/archive/flows/claude-code-v2-flow.md, section 6) so that
  the model operating this tool follows the same commit discipline:

    * New commits over `--amend` (prevents overwriting published history)
    * Specific-file staging (no `git add .` / `git add -A`)
    * No `--force` to shared branches
    * No `--no-verify` (hook bypass)
    * Match the repo's existing commit style (why > what)
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Run git subcommands on a local repository: status, diff, log, show, add,
    commit, branch, checkout, stash, reset, tag, remote, blame, shortlog,
    describe, reflog.

    Git Safety Protocol (mandatory):
    - Before committing, run `git status`, `git diff HEAD`, and
      `git log --oneline -10` to match the repo's commit style; messages
      explain WHY, not WHAT.
    - Stage named paths only — never `git add .` or `-A`.
    - Prefer a NEW commit over `--amend`; if a hook fails, fix the cause and
      commit again.
    - Never commit, push, or delete branches unless explicitly asked.
    - Blocked and will error: `push --force`/`-f`/`--force-with-lease`,
      `commit --no-verify`, `reset --hard`, `clean -f`, `checkout .`,
      `restore .`, `branch -D`.
    """
  end
end
