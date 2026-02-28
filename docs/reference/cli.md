# CLI Command Reference

> Complete reference for all 60+ slash commands

## Entry Points

```bash
osagent              # Interactive chat (default)
osagent setup        # Configuration wizard
osagent serve        # Headless HTTP API mode
osagent version      # Print version
```

---

## Info & Status

| Command | Description |
|---------|-------------|
| `/help` | List available commands |
| `/status` | System status (provider, model, channels, memory) |
| `/doctor` | Run diagnostics (providers, channels, sidecars, database) |
| `/config` | Show runtime configuration |
| `/banner` | Show OSA Agent banner |

## Model & Provider

| Command | Description |
|---------|-------------|
| `/model` | Show current provider and model |
| `/model <provider>/<model>` | Switch to specific provider/model (e.g., `/model anthropic/claude-3`) |
| `/model <name>` | Switch Ollama model by name |
| `/models` | Open interactive model picker (TUI) or list models (CLI) |
| `/provider` | Show provider details |
| `/theme` | List available TUI themes |
| `/theme <name>` | Switch TUI theme (persisted to ~/.osa/tui.json) |

## Session Management

| Command | Description |
|---------|-------------|
| `/new` | Start fresh session |
| `/sessions` | List stored sessions |
| `/resume <id>` | Resume previous session |
| `/history` | View current session history |
| `/history search <query>` | Search across session history |
| `/clear` | Clear current display |
| `/exit` or `/quit` | Exit OSA |

## Memory

| Command | Description |
|---------|-------------|
| `/memory` | Show memory stats |
| `/mem-search <query>` | Search memory for patterns, solutions, decisions |
| `/mem-save <type>` | Save to memory (decision, pattern, solution, context) |
| `/mem-recall <topic>` | Recall specific topic from memory |
| `/mem-list` | List entries in memory collections |
| `/mem-stats` | Detailed memory statistics |
| `/mem-delete <id>` | Delete a memory entry |
| `/mem-context` | Save current conversation context to memory |
| `/mem-export` | Export memory collections to file |

## Context & Performance

| Command | Description |
|---------|-------------|
| `/compact` | Show context compaction stats |
| `/usage` | Token usage breakdown |
| `/cortex` | Cortex bulletin and active topics |
| `/verbose` | Toggle verbose output mode |
| `/think <level>` | Set reasoning depth: fast, normal, deep |

## Agents & Orchestration

| Command | Description |
|---------|-------------|
| `/agents` | List 22+ agents with roles and tiers |
| `/tiers` | Show tier assignments and budgets |
| `/swarms` | List available swarm patterns (10 presets) |
| `/orchestrate <task>` | Launch multi-agent orchestration |
| `/budget` | Current spend vs limits |
| `/hooks` | List registered hooks with priorities |
| `/learning` | Learning engine metrics and recent patterns |

## Channels

| Command | Description |
|---------|-------------|
| `/channels` | List all channels and status |
| `/channels status` | Detailed connection info |
| `/channels connect <name>` | Manually connect a channel |
| `/channels disconnect <name>` | Disconnect a channel |
| `/channels test <name>` | Send test message |
| `/whatsapp connect` | Connect WhatsApp Web sidecar |
| `/whatsapp test` | Test WhatsApp connection |

## Skills

| Command | Description |
|---------|-------------|
| `/skills` | List available skills (built-in + custom) |
| `/soul` | Show current personality configuration |
| `/reload` | Reload soul, skills, and config from disk |
| `/create-command` | Create a custom slash command |

## Scheduling

| Command | Description |
|---------|-------------|
| `/schedule` | Show scheduled tasks |
| `/cron add <spec> <task>` | Add a cron job |
| `/cron run <id>` | Manually trigger a cron job |
| `/cron enable <id>` | Enable a cron job |
| `/cron disable <id>` | Disable a cron job |
| `/cron remove <id>` | Remove a cron job |
| `/triggers add <event> <action>` | Add an event trigger |
| `/triggers remove <id>` | Remove a trigger |
| `/heartbeat` | Show heartbeat status |

## Development Workflow

| Command | Description |
|---------|-------------|
| `/commit` | Create a git commit with proper format |
| `/build` | Build project with intelligent detection |
| `/test` | Run tests with intelligent detection |
| `/lint` | Run linting with auto-fix |
| `/verify` | Run verification checklist |
| `/create-pr` | Create a pull request |
| `/fix` | Apply fixes from review/debug session |
| `/explain` | Explain code, concepts, or decisions |
| `/refactor` | Safe code refactoring |
| `/review` | Code review on recent changes |
| `/pr-review` | Review a PR, identify issues |
| `/debug` | Start systematic debugging |
| `/search` | Search codebase, memory, and documentation |

## Context Priming

| Command | Description |
|---------|-------------|
| `/prime` | Show what context is loaded |
| `/prime-backend` | Load Go backend development context |
| `/prime-webdev` | Load React/Next.js/TypeScript context |
| `/prime-svelte` | Load Svelte/SvelteKit context |
| `/prime-security` | Load security audit context |
| `/prime-devops` | Load DevOps/infrastructure context |
| `/prime-testing` | Load testing/QA context |
| `/prime-osa` | Load OSA Terminal development context |
| `/prime-miosa` | Load MIOSA platform context |

## Security

| Command | Description |
|---------|-------------|
| `/security-scan` | Run comprehensive security scan |
| `/secret-scan` | Detect hardcoded secrets |
| `/harden` | Security hardening recommendations |

## Analytics & System

| Command | Description |
|---------|-------------|
| `/analytics` | Session and learning analytics |
| `/tasks` | Task tracking status |
| `/init` | Initialize for a new project |
| `/setup` | Run configuration wizard |
