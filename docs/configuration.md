# OSA Configuration (`~/.osa/config.toml`)

OSA has a single, standard, user-editable configuration file:

```
~/.osa/config.toml
```

It is safe to edit by hand. OSA re-reads it automatically when the file's
modification time changes — no restart required. A fully-commented template is
seeded on first run (and shipped at `priv/templates/config.toml`).

The loader is `OptimalSystemAgent.ConfigFile`.

---

## Precedence

Configuration is resolved by a recursive **deep-merge**, lowest → highest:

```
built-in defaults   <   ~/.osa/config.json   <   ~/.osa/config.toml
```

1. **Built-in defaults** — `ConfigFile.defaults/0`. Always present.
2. **`config.json`** — the legacy selection written by onboarding and the
   in-TUI model picker (`{"model": ..., "provider": ...}`). Read as a
   fallback/overlay so existing installs keep working with zero migration.
3. **`config.toml`** — the first-class config. Anything set here wins.

Because merging is recursive over maps, you only specify the keys you want to
change; everything omitted falls through to the default.

---

## Schema

### `[model]`

| Key       | Type   | Meaning                                                   |
|-----------|--------|-----------------------------------------------------------|
| `provider`| string | LLM backend id (`ollama`, `miosa`, `openai`, …)           |
| `model`   | string | Model slug for that provider                              |
| `effort`  | string | Reasoning-effort hint (`low`/`medium`/`high`)             |
| `params`  | table  | Free-form generation params, forwarded as-is to provider  |

```toml
[model]
provider = "ollama"
model = "glm-4.7:cloud"
effort = "high"

[model.params]
temperature = 0.7
max_tokens = 8192
```

Typed getters: `ConfigFile.provider/0`, `model_name/0`, `effort/0`,
`model_params/0`.

### `[permissions]`

Extends/overrides the shell three-tier permission gate (see the
`shell_execute` security model). Every list here is **additive** — merged on
top of OSA's built-in defaults in
`OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants`, never replacing
them.

| Key                     | Type          | Effect                                                        |
|-------------------------|---------------|--------------------------------------------------------------|
| `ask_commands`          | list<string>  | Extra command names that require approval (risky `:ask` tier) |
| `ask_patterns`          | list<regex>   | Extra regexes that route a command to the approval prompt     |
| `catastrophic_patterns` | list<regex>   | Extra regexes that HARD-DENY a command (never offered)        |
| `allow`                 | list<string>  | Downgrade to run-without-prompt. Bare command name or regex.  |
| `deny`                  | list<string>  | Hard-deny. Bare command name or regex.                        |

```toml
[permissions]
ask_commands = ["deploy", "terraform"]
ask_patterns = ['\bdocker\s+system\s+prune\b']
catastrophic_patterns = ['\bterraform\s+destroy\b']
allow = ["git", "docker"]
deny = ["shutdown", "reboot"]
```

**Override semantics** (evaluated per command):

1. `catastrophic` (defaults + `catastrophic_patterns` + `deny` patterns) →
   **hard-deny**. Checked first.
2. `deny` command heads → **hard-deny**.
3. `allow` (command heads or patterns) → **run without prompt**. Can never
   downgrade a catastrophic/deny match — safety always wins.
4. `risky` (defaults + `ask_commands` + `ask_patterns`) → **approval prompt**.
5. everything else → **allowed**.

An `allow` entry is a bare command name if it is only word characters, dots
and dashes (matched against each command head); otherwise it is compiled as a
regex. Same for `deny`.

### `[shell]`

| Key          | Type | Meaning                                                    |
|--------------|------|------------------------------------------------------------|
| `timeout_ms` | int  | Wall-clock cap for one foreground command. Default 120000. |

The per-call env var `OSA_SHELL_TIMEOUT_MS` still overrides this at runtime.

### `[tui]`

| Key         | Type   | Meaning                              |
|-------------|--------|--------------------------------------|
| `theme`     | string | `dark` (default) or `light`          |
| `verbosity` | string | `quiet` / `normal` / `verbose`       |

### `[mcp_servers.*]`

Pass-through Model Context Protocol server definitions, Codex-compatible in
shape. Each server is its own table `[mcp_servers.<name>]` with either a
`command` (+ optional `args`, `env`) for a stdio server or a `url` for a remote
one. `enabled = false` keeps a definition without loading it.

```toml
[mcp_servers.linear]
url = "https://mcp.linear.app/mcp"

[mcp_servers.local-tools]
command = "bun"
args = ["run", "packages/mcp/src/bin.ts"]
enabled = true
```

Accessed via `ConfigFile.mcp_servers/0` (raw table, name → definition map).

---

## Programmatic API

```elixir
ConfigFile.load()                # fully-merged config map
ConfigFile.get(["model","provider"], "ollama")
ConfigFile.provider()            # typed getters
ConfigFile.shell_timeout_ms()
ConfigFile.mcp_servers()
ConfigFile.reload()              # force re-read (also automatic on mtime change)
ConfigFile.write_default_template()  # seed ~/.osa/config.toml if absent
```

The shell gate consumes the config through `Constants.effective_ask_commands/0`,
`effective_ask_patterns/0`, `effective_catastrophic_patterns/0`,
`deny_commands/0`, `allow_commands/0`, `allow_patterns/0`, and
`effective_timeout_ms/0`. The raw `ask_commands/0`, `ask_patterns/0`,
`catastrophic_patterns/0`, and `default_timeout_ms/0` accessors still return the
built-in baseline unchanged.

---

## Robustness

- A malformed `config.toml` logs a warning and falls back to defaults; it never
  crashes the agent or the permission gate.
- The merged config is cached in `:persistent_term`, keyed by path + both
  files' mtimes, so edits are picked up automatically.
- `write_default_template/0` never clobbers an existing config.
