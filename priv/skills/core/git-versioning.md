---
name: git-versioning
description: "Self-versioning workflow for OSA: conventional commits → semver → changelog → tag → push. Auto-triggers on version/release/tag/changelog requests."
triggers: version | release | semver | tag | changelog | bump version | new release | publish
user-invocable: true
priority: high
---

# Git Self-Versioning Workflow

Use this workflow whenever the task involves releasing, tagging, or versioning the project.

## The Flow: COMMIT → INSPECT → BUMP → CHANGELOG → TAG → PUSH

---

### Step 1: Ensure Conventional Commits Are in Place

Before tagging, verify recent commits follow the format:
```
<type>(<scope>): <subject>

Types: feat | fix | perf | refactor | docs | test | chore
Breaking change: add ! after type/scope, e.g. feat(api)!: rename endpoint
```

Use `git` tool with `operation: "log"` + `format: "conventional"` to inspect recent commits.

---

### Step 2: Find the Current Version

```
git tool:
  operation: "tag"
  tag_action: "latest"
```

Returns the most recent semver tag (e.g., `v1.3.0`) or `(no tags yet)` for a fresh project.

---

### Step 3: Inspect Commits Since Last Tag

```
git tool:
  operation: "log"
  since: "v1.3.0"       ← use the tag from step 2
  format: "conventional" ← grouped output for changelog
```

Analyze the output to determine version bump:
- Any `BREAKING CHANGES` → **major** bump (1.x.x → 2.0.0)
- Any `feat:` commits → **minor** bump (1.3.x → 1.4.0)
- Only `fix:` / `perf:` / `chore:` → **patch** bump (1.3.0 → 1.3.1)

---

### Step 4: Calculate New Version

Apply semver rules to the current version:
- Current: `v1.3.0`
- Breaking change → `v2.0.0`
- New feature → `v1.4.0`
- Only fixes → `v1.3.1`

For pre-releases: append `-alpha.1`, `-beta.1`, `-rc.1`.

---

### Step 5: Update Version Files

For OSA, version is declared in `mix.exs`:
```elixir
def project do
  [
    app: :optimal_system_agent,
    version: "1.3.0",   ← update this
    ...
  ]
end
```

If the Rust TUI needs versioning, also update `priv/rust/tui/Cargo.toml`:
```toml
[package]
version = "1.3.0"   ← update this
```

Use `file_edit` tool to update. Commit the version bump:
```
git tool:
  operation: "commit"
  message: "chore(release): bump version to v1.4.0"
```

---

### Step 6: Create the Tag

```
git tool:
  operation: "tag"
  tag_action: "create"
  tag_name: "v1.4.0"
  tag_message: "Release v1.4.0\n\n<paste changelog here>"
```

Use an **annotated tag** (with `tag_message`) for releases — it stores the changelog in the tag object.

---

### Step 7: Push Tag to Remote

```
git tool:
  operation: "tag"
  tag_action: "push"
  tag_name: "v1.4.0"
```

Or push all tags at once (omit `tag_name`).

---

## Quick Reference

| Goal | Tool Call |
|------|-----------|
| What's the current version? | `tag latest` |
| What changed since v1.3.0? | `log since="v1.3.0" format="conventional"` |
| Create tag v1.4.0 | `tag create name="v1.4.0" message="..."` |
| Push tag to remote | `tag push name="v1.4.0"` |
| List all tags | `tag list` |
| Delete a bad tag | `tag delete name="v1.4.0-bad"` |

## Semver Quick Rules

```
BREAKING (feat! or fix! or BREAKING CHANGE:)  → major  X.0.0
New feature (feat:)                            → minor  x.X.0
Bug fix / perf / chore (fix:, perf:, chore:)  → patch  x.x.X
```

## Anti-Patterns

- Do NOT create tags on uncommitted work — run `git status` first
- Do NOT skip the version file update — tag and mix.exs must match
- Do NOT use non-semver tag names (e.g. "release-jan" instead of "v1.4.0")
- Do NOT push force-delete a tag that's already on remote (breaks consumers)
