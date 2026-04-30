defmodule OptimalSystemAgent.Tools.Builtins.Git.Prompt do
  @moduledoc """
  Dynamic prompt for the `git` tool.

  Encodes the Git Safety Protocol drawn from the Claude Code v2 flow
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
    Run git commands on a local repository.

    ## Supported subcommands
    status, diff, log, show, add, commit, branch, checkout, stash,
    reset, tag, remote, blame, shortlog, describe, reflog.

    ## Parameters
    - `command` (required): the git subcommand (e.g. "status", "commit").
    - `args` (optional): additional flags and arguments as a single string.
    - `path` (optional): working directory. Defaults to ~/.osa/workspace.

    ## Git Safety Protocol (MANDATORY — follow every rule)

    ### Committing
    1. Before committing, run `git status` and `git diff HEAD` in parallel to
       understand exactly what changed.
    2. Run `git log --oneline -10` to read the repo's existing commit style
       (tense, scope, verbosity) and match it precisely.
    3. Write commit messages that explain WHY, not WHAT.
       Good: "fix: prevent session crash when SSE reconnects mid-stream"
       Bad:  "fix: update sse.go"
    4. Stage SPECIFIC files only — never `git add .` or `git add -A`.
       Always name the exact file paths: `git add path/to/file.ex`.
    5. Prefer creating a NEW commit over amending an existing one.
       If a pre-commit hook fails, fix the underlying issue and create a
       new commit. Never use `--amend` on published commits.

    ### Absolute prohibitions — these are BLOCKED and will return an error
    - `git push --force` / `git push -f` — force push to any remote
    - `git push --force-with-lease` — force push to shared branches
    - `git commit --no-verify` — hook bypass
    - `git reset --hard` — destructive working-tree wipe
    - `git clean -f` — destructive untracked-file removal
    - `git checkout .` / `git restore .` — discards all local changes
    - `git branch -D` — force-deletes a branch
    - `git add .` / `git add -A` — indiscriminate staging (warn, not blocked)

    ### Never do without being explicitly asked
    - Commit changes
    - Push to a remote
    - Delete branches

    ### Safe defaults
    - Read-only operations (status, diff, log, show) are always safe.
    - When in doubt, use `git status` first to assess the working tree.
    - Use `git stash` to safely set aside uncommitted changes.
    """
  end
end
