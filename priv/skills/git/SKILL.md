---
name: git
description: "Superhuman git operations — commit, branch, blame, search history (grep+pickaxe), cherry-pick, worktrees, bisect, reflog, stash, PR diff. Auto-triggers on git/commit/branch/merge/blame/bisect/history/diff/PR requests."
triggers:
  - git
  - commit
  - branch
  - merge
  - stash
  - blame
  - bisect
  - history
  - diff
  - PR
  - pull request
  - cherry-pick
  - worktree
  - reflog
  - search history
priority: 2
---

# Git Skill — Superhuman Git Operations

Use the `git` tool for ALL version control tasks. Never use `shell_execute` for git commands.

## Available Operations

| Operation     | Purpose                                                      |
|---------------|--------------------------------------------------------------|
| `status`      | Show working tree state                                      |
| `diff`        | Show unstaged or staged changes                              |
| `log`         | Show commit history (oneline/full/conventional)              |
| `commit`      | Stage all + commit with message                              |
| `add`         | Stage specific files                                         |
| `push`        | Push to remote                                               |
| `pull`        | Pull from remote                                             |
| `clone`       | Clone a repository                                           |
| `branch`      | List, create, or switch branches                             |
| `show`        | Inspect a specific commit                                    |
| `stash`       | Save/restore/list/drop WIP changes                           |
| `reset`       | Unstage or undo commits                                      |
| `remote`      | List or add remotes                                          |
| `tag`         | List/create/delete/push semver tags                          |
| `blame`       | Show line-level authorship for a file                        |
| `search`      | Search commit messages (grep) and code changes (pickaxe)     |
| `cherry_pick` | Apply specific commits to current branch                     |
| `worktree`    | Manage parallel worktrees for concurrent work                |
| `bisect`      | Binary search to find the commit that broke things           |
| `reflog`      | Show reflog for recovering lost commits/branches             |
| `pr_diff`     | Show diff between base branch and HEAD (PR review)           |

---

## Workflow Guidelines

### Before Committing
Always check state first:
```
git tool: operation=status
git tool: operation=diff
```

### Commit Messages (Mandatory Format)
Use conventional commits: `type(scope): subject`

Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `chore`
Breaking change: add `!` — e.g., `feat(api)!: rename endpoint`

Good examples:
- `feat(auth): add JWT refresh token rotation`
- `fix(db): prevent connection pool exhaustion on timeout`
- `chore(deps): upgrade phoenix to 1.8`

### Atomic Commits
One logical change per commit. Never bundle unrelated changes.

---

## Advanced Operation Guides

### blame — Find Who Wrote This Code

Show authorship for an entire file:
```
git tool: operation=blame, file="lib/my_module.ex"
```

Show authorship for specific lines (e.g., lines 45-60):
```
git tool: operation=blame, file="lib/my_module.ex", line_start=45, line_end=60
```

Use before raising a bug report to understand context and history.

---

### search — Mine History

**Grep** — find commits whose messages mention a keyword:
```
git tool: operation=search, query="rate limit", search_type=grep
```

**Pickaxe** — find commits that added or removed a string in code:
```
git tool: operation=search, query="MyModule.dangerous_fn", search_type=pickaxe
```

**Both** (default) — run both searches and return combined results:
```
git tool: operation=search, query="API_KEY"
```

Use pickaxe to find when a function was introduced or deleted.
Use grep to find when a feature or ticket was discussed in commits.

---

### cherry_pick — Apply Specific Commits

Apply one commit:
```
git tool: operation=cherry_pick, ref="abc1234"
```

Apply multiple commits (space-separated):
```
git tool: operation=cherry_pick, ref="abc1234 def5678 ghi9012"
```

Stage changes without committing yet:
```
git tool: operation=cherry_pick, ref="abc1234", no_commit=true
```

If a conflict is reported: resolve files, `git add` them, then `git cherry-pick --continue`.

---

### worktree — Work on Multiple Branches in Parallel

List all worktrees:
```
git tool: operation=worktree, worktree_action=list
```

Create a new worktree for a feature branch:
```
git tool: operation=worktree, worktree_action=add, worktree_path="feature-auth", branch_name="feature/auth"
```

Remove a worktree when done:
```
git tool: operation=worktree, worktree_action=remove, worktree_path="feature-auth"
```

Each worktree is an independent checkout — no stashing needed. Ideal for reviewing a PR while working on another branch.

---

### bisect — Binary Search for Bugs

**Option A: Manual bisect**

1. Start with known good and bad refs:
```
git tool: operation=bisect, bisect_action=start, good_ref="v1.2.0", bad_ref="HEAD"
```

2. Mark each commit as good or bad after testing:
```
git tool: operation=bisect, bisect_action=good
git tool: operation=bisect, bisect_action=bad
```

3. End the session:
```
git tool: operation=bisect, bisect_action=reset
```

**Option B: Automated bisect** (fastest)
```
git tool: operation=bisect, bisect_action=start, good_ref="v1.2.0"
git tool: operation=bisect, bisect_action=run, bisect_command="mix test test/regression_test.exs"
```

The test command must exit 0 for good, non-0 for bad.
Allowed executables: `mix`, `elixir`, `cargo`, `go`, `npm`, `yarn`, `pytest`, `python`, `ruby`, `bash`, `sh`.

Check bisect progress:
```
git tool: operation=bisect, bisect_action=log
```

---

### reflog — Recover Lost Work

Show the last 20 HEAD movements:
```
git tool: operation=reflog
```

Show reflog for a specific branch:
```
git tool: operation=reflog, ref="feature/my-branch", count=30
```

To restore a lost commit after accidental reset: find the SHA in reflog output, then create a recovery branch pointing to it.

---

### pr_diff — Review What Your PR Changes

Show all changes your feature branch introduces vs main:
```
git tool: operation=pr_diff
```

Against a different base branch:
```
git tool: operation=pr_diff, base_branch="develop"
```

Uses `git diff base...HEAD` (three dots) — shows only commits on your branch.

---

## Anti-Patterns

- Do NOT use `shell_execute` for git — use the `git` tool (injection-safe)
- Do NOT `git add -A` blindly — check `diff` first to confirm what you are staging
- Do NOT commit without a conventional commit message
- Do NOT bundle unrelated changes in one commit — keep commits atomic
- Do NOT run `bisect run` with arbitrary executables — only approved test commands
- Do NOT hard reset without first checking `reflog` to confirm you have a recovery path

---

## Quick Reference

| Goal | Operation |
|------|-----------|
| Who wrote line 42 of auth.ex? | `blame, file="lib/auth.ex", line_start=42, line_end=42` |
| When was `deprecated_fn` deleted? | `search, query="deprecated_fn", search_type=pickaxe` |
| Apply hotfix commit to release branch | `cherry_pick, ref="<sha>"` |
| Work on auth + fix simultaneously | `worktree add` for each branch |
| Find when tests started failing | `bisect run, bisect_command="mix test"` |
| Recover from accidental reset | `reflog` then `branch` to SHA |
| Review PR changes cleanly | `pr_diff, base_branch="main"` |
