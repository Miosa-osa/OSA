# priv/ Asset Setup

## What's in priv/

`priv/` is Elixir's convention for bundled resources that ship with the app. At runtime, code accesses these via `:code.priv_dir(:optimal_system_agent)`. User overrides live in `~/.osa/` and take priority.

## Assets Added

### Agent Definitions (`priv/agents/`)
**38 specialist .md files** + `agent-ecosystem.json` across 4 subdirs (specialists, combat, elite, security).

Each .md is a prompt/definition file for an agent type (api-designer, architect, debugger, etc).

**Wired in**: `roster.ex` → `load_definition(agent_name)` reads `.md` from `priv/agents/{specialists,combat,elite,security}/` at boot. Already working.

### Taskmaster Commands (`priv/commands/taskmaster/`)
**43 .md files** — command definitions for the task management system (add-task, expand-task, tm-list, etc).

**Wired in**: `prompt_loader.ex` → `load_command_prompts/0` scans `priv/commands/` for `category/name.md` at boot. Merges with `~/.osa/commands/` (user overrides bundled). Already working.

### Rules (`priv/rules/`)
**9 .md files** across `api/`, `behaviors/`, `frontend/`, plus `testing.md` and `typescript.md`.

**Wired in**: Static reference. No loader yet — future work to add discovery similar to prompt_loader.

### Skills Library (`priv/skills/library/`)
**4 .json files** — `index.json` + 3 auto-generated skill definitions (async-parallel-dispatch, weighted-memory-retrieval, simplemem-compression).

The index maps skill IDs → tags/metadata. Each JSON has a code snippet + usage stats.

**Wired in**: NOT yet. `registry.ex` only scans for `.md` files (SKILL.md). These JSON files are inert — future work to add a JSON skill loader.

### Skills Learning Engine Resource (`priv/skills/learning-engine/resources/`)
**1 .md file** — reference doc for advanced metrics. Passive context for the learning engine SKILL.md.

## Path Convention

All files reference `~/.osa/` (not `~/.claude/`). Any scripts that pointed to the old path were fixed.

## What Loads at Boot vs What's Static

| Asset | Loaded at boot? | By what? |
|-------|-----------------|----------|
| agents/**/*.md | Yes | `roster.ex` → `load_definition/1` |
| agents/agent-ecosystem.json | No | Static reference |
| commands/taskmaster/*.md | Yes | `prompt_loader.ex` → `load_command_prompts/0` |
| rules/**/*.md | No | Static — needs loader |
| skills/library/*.json | No | Registry only scans .md |
| skills/**/SKILL.md | Yes | `registry.ex` → `load_skill_definitions/0` |
