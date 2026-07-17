# Feature Flags

All opt-in features in OSA are disabled by default. Each flag activates a
distinct subsystem that is conditionally included in the supervision tree at
boot by `Supervisors.Extensions`.

## Flag Summary

| Feature | Env Var | Config Key | Default |
|---------|---------|------------|---------|
| Sandbox | `OSA_SANDBOX_ENABLED=true` | `sandbox_enabled` | `false` |
| Treasury | `OSA_TREASURY_ENABLED=true` | `treasury_enabled` | `false` |
| Fleet | `OSA_FLEET_ENABLED=true` | `fleet_enabled` | `false` |
| Wallet | `OSA_WALLET_ENABLED=true` | `wallet_enabled` | `false` |
| OTA Updater | `OSA_UPDATE_ENABLED=true` | `update_enabled` | `false` |
| AMQP | `AMQP_URL=<url>` | `amqp_url` | `nil` |
| Python Sidecar | `OSA_PYTHON_SIDECAR=true` | `python_sidecar_enabled` | `false` |
| Go Tokenizer | `OSA_GO_TOKENIZER=true` | `go_tokenizer_enabled` | `false` |
| Go Git | config only | `go_git_enabled` | `false` |
| Go Sysmon | config only | `go_sysmon_enabled` | `false` |
| WhatsApp Web | config only | `whatsapp_web_enabled` | `false` |
| Plan Mode | `OSA_PLAN_MODE=true` | `plan_mode_enabled` | `false` |
| Extended Thinking | `OSA_THINKING_ENABLED=true` | `thinking_enabled` | `false` |

Always-on extensions (started unconditionally, dormant until wired):

| Feature | Notes |
|---------|-------|
| Intelligence | **PLANNED / NOT IMPLEMENTED** — `ConversationTracker`, `ContactDetector`, `ProactiveMonitor` do not exist in `lib/`; no `Intelligence.Supervisor` is started |
| Swarm | `Mailbox`, `SwarmMode`, `AgentPool` (max 50 children) |

## Sandbox

Isolates tool execution in a Docker container (or BEAM process). Prevents agent
code execution from affecting the host filesystem or network beyond controlled
mounts.

**Enable:** `OSA_SANDBOX_ENABLED=true`

**Modes:**
- `:docker` (default) — OS-level isolation via Docker
- `:beam` — BEAM process isolation only (no Docker required)
- Sprites.dev — remote WASM sandbox via `SPRITES_TOKEN`

**Key settings:**

```elixir
sandbox_image: "osa-sandbox:latest"   # build with: mix osa.sandbox.setup
sandbox_network: false                 # --network none (no outbound network)
sandbox_max_memory: "256m"
sandbox_max_cpu: "0.5"
sandbox_timeout: 30_000                # ms per command
sandbox_workspace_mount: true          # mount ~/.osa/workspace at /workspace
sandbox_read_only_root: true
sandbox_no_new_privileges: true
sandbox_capabilities_drop: ["ALL"]
```

Allowed images for skill `:image` option:

```elixir
sandbox_allowed_images: [
  "osa-sandbox:latest",
  "python:3.12-slim",
  "node:22-slim"
]
```

## Treasury

Financial governance layer with a transaction ledger. Wraps all LLM API spend
in a double-entry accounting system with approval workflows for large
transactions.

**Enable:** `OSA_TREASURY_ENABLED=true`

**Settings:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_TREASURY_DAILY_LIMIT` | `250.0` | Daily spend cap (USD) |
| `OSA_TREASURY_MAX_SINGLE` | `50.0` | Max single transaction (USD) |
| `OSA_TREASURY_AUTO_DEBIT` | `true` | Auto-debit approved amounts |

Treasury runs as `MiosaBudget.Treasury` under `Supervisors.Extensions`. When
enabled, all LLM calls route spend through the Treasury ledger rather than the
basic budget counter.

## Fleet

Remote agent fleet registry with sentinel monitoring. Allows OSA to coordinate
work across multiple agent instances on different hosts.

**Enable:** `OSA_FLEET_ENABLED=true`

Starts `OptimalSystemAgent.Fleet.Supervisor`, which manages:
- Fleet registry (tracks agent instances, their capabilities, and health)
- Sentinel monitors (detect unreachable agents and reroute work)

## Wallet

Crypto wallet connectivity for on-chain payments and token management.

**Enable:** `OSA_WALLET_ENABLED=true`

**Settings:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_WALLET_PROVIDER` | `mock` | Wallet backend identifier |
| `OSA_WALLET_ADDRESS` | — | Wallet public address |
| `OSA_WALLET_RPC_URL` | — | Blockchain RPC endpoint |

When enabled, starts `Integrations.Wallet` and `Integrations.Wallet.Mock`
(development mock) under `Supervisors.Extensions`.

## OTA Updater

Secure over-the-air updates using TUF (The Update Framework) for cryptographic
verification of update packages.

**Enable:** `OSA_UPDATE_ENABLED=true`

**Settings:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_UPDATE_URL` | — | TUF update server URL (required) |
| `OSA_UPDATE_INTERVAL` | `86400000` | Check interval in ms (24 hours) |

Starts `OptimalSystemAgent.System.Updater` under `Supervisors.Extensions`.

## AMQP (RabbitMQ)

Publishes OSA events to a RabbitMQ exchange for Go worker consumption in
platform deployments.

**Enable:** Set `AMQP_URL` to a valid AMQP connection URL.

```
AMQP_URL=amqp://user:password@rabbitmq:5672/vhost
```

Starts `OptimalSystemAgent.Platform.AMQP` under `Supervisors.Extensions`.
The AMQP publisher subscribes to `Events.Bus` and forwards selected event
types to the configured exchange.

## Python Sidecar

Runs a Python subprocess for semantic memory search using local sentence
embeddings. When disabled, memory search falls back to keyword-based retrieval.

**Enable:** `OSA_PYTHON_SIDECAR=true`

**Requirements:** Python 3 with `sentence-transformers` installed.

**Settings:**

```elixir
python_sidecar_model: "all-MiniLM-L6-v2"  # embedding model
python_sidecar_timeout: 30_000              # ms per embedding request
python_path: "python3"                      # override with OSA_PYTHON_PATH
```

Starts `OptimalSystemAgent.Python.Supervisor` under `Supervisors.Extensions`.

## Go Tokenizer

Replaces the word-count heuristic for token estimation with accurate BPE token
counting via a pre-built Go binary.

**Enable:** `OSA_GO_TOKENIZER=true`

**Requirements:** Pre-built Go binary at `priv/go/tokenizer/osa-tokenizer`.
Build before `mix release` (CI handles this in a prior step).

**Settings:**

```elixir
go_tokenizer_encoding: "cl100k_base"  # tiktoken encoding
```

Starts `OptimalSystemAgent.Go.Tokenizer` under `Supervisors.Extensions`. When
the binary is missing, falls back to the word-count heuristic without error.

## Go Git

Go sidecar providing enhanced git operations (blame, log streaming, large repo
operations) beyond what the Elixir git tools support.

**Enable:** Set `go_git_enabled: true` in `config/config.exs` or via runtime
config injection.

Starts `OptimalSystemAgent.Go.Git` under `Supervisors.Extensions`.

## Go Sysmon

Go sidecar providing system monitoring metrics (CPU, memory, disk, network) with
low overhead. Used by the `system_info` tool to provide accurate host metrics.

**Enable:** Set `go_sysmon_enabled: true` in config.

Starts `OptimalSystemAgent.Go.Sysmon` under `Supervisors.Extensions`.

## WhatsApp Web

WhatsApp Web integration for receiving and sending messages via WhatsApp. Uses
the Baileys protocol implementation via a Node.js sidecar.

**Enable:** Set `whatsapp_web_enabled: true` in config.

Starts `OptimalSystemAgent.WhatsAppWeb` under `Supervisors.Extensions`.

## Plan Mode

When active, the agent makes a single LLM call with no tool iterations. The LLM
produces a structured plan as its sole output. Useful for high-level task
decomposition before execution.

**Enable:** `OSA_PLAN_MODE=true` (sets `plan_mode_enabled: true`; individual
sessions can toggle via `/plan` command)

## Extended Thinking

Enables extended thinking budget for LLM providers that support it (Anthropic
Claude). The model receives additional tokens to reason internally before
producing a response.

**Enable:** `OSA_THINKING_ENABLED=true`

**Settings:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `OSA_THINKING_BUDGET` | `5000` | Token budget for thinking phase |

## Sidecar Manager

`OptimalSystemAgent.Sidecar.Manager` starts unconditionally and manages all Go
and Python sidecars. It creates the sidecar registry and circuit breaker ETS
tables. Individual sidecars are only started when their feature flag is active.

The manager provides:
- Sidecar process registration
- Circuit breaker state for each sidecar (prevents cascading failures)
- Health check coordination
