# Infrastructure: Sandbox

The sandbox system provides isolated execution environments for agent-generated code. OSA supports three sandbox backends: Docker containers, BEAM Tasks (in-process isolation), and WASM runtimes. Sandboxes are managed by a pool, provisioner, and registry.

---

## Overview

```
Agent.Loop
  -> Tools.CodeSandbox
     -> Sandbox.Pool.acquire()
        -> Sandbox.Provisioner.start()
        -> Sandbox.Registry.register()
     -> execute(code, sandbox)
     -> Sandbox.Pool.release(sandbox)
```

The `code_sandbox` builtin tool is the primary consumer. Sandboxes are pooled for efficiency — a warm Docker container or WASM runtime can be reused across multiple tool calls within a session.

---

## Backends

### Docker

Runs code in isolated Docker containers. Each container:
- Has a configurable image (default: a lightweight language-specific runtime image).
- Has resource limits: CPU, memory, and execution timeout.
- Has no network access by default.
- Is removed after release (or on pool eviction).

**Configuration:**

```elixir
config :optimal_system_agent,
  sandbox_backend: :docker,
  sandbox_docker_image: "osa-sandbox:latest",
  sandbox_timeout_ms: 30_000,
  sandbox_memory_mb: 256,
  sandbox_cpu_shares: 512
```

### BEAM Tasks

Runs code in an isolated BEAM `Task` under a dedicated supervisor with a restricted process dictionary. Suitable for Elixir/Erlang code evaluation.

- No file system access outside a temp directory.
- No network access.
- Killed after timeout.

**Configuration:**

```elixir
config :optimal_system_agent,
  sandbox_backend: :beam_task,
  sandbox_timeout_ms: 10_000
```

### WASM

Runs code in a WebAssembly runtime (e.g. Wasmtime). Provides the strongest isolation for untrusted code but supports only WASM-compiled languages.

**Configuration:**

```elixir
config :optimal_system_agent,
  sandbox_backend: :wasm,
  sandbox_wasm_runtime: :wasmtime,
  sandbox_timeout_ms: 15_000
```

---

## Backend selection (`~/.osa/sandbox.json`)

`Sandbox.Router` owns backend selection, config loading, and host-fallback.
Shell/code execution is routed through the Router whenever a non-host backend
is configured (or `mode` is `required`); otherwise the existing host execution
path is used unchanged. **Default is `host` — no behavior change unless you
opt in.**

Create `~/.osa/sandbox.json` to select and configure a backend:

```json
{
  "backend": "miosa",
  "mode": "required",
  "miosa":  { "api_key": "…", "size": "medium", "timeout": 60 },
  "docker": { "image": "osa-sandbox:latest", "memory": "256m", "network": false, "timeout": 30 },
  "e2b":    { "api_key": "…", "template": "base", "timeout": 60 },
  "vercel": { "token": "…", "team_id": "…", "project_id": "…", "runtime": "node20", "timeout": 60 }
}
```

| Field | Values | Meaning |
|-------|--------|---------|
| `backend` | `host` \| `docker` \| `e2b` \| `miosa` \| `vercel` | Which sandbox to route execution through. |
| `mode` | `optional` (default) \| `required` | `optional` falls back to the host if the backend is unavailable; `required` hard-fails execution instead of falling back (never silently runs on the host). |

**Selection precedence** (see `Sandbox.Router`):

1. Explicit `:sandbox_backend` in application env / `backend` in `sandbox.json`.
2. Env-var auto-detection — `MIOSA_PLATFORM_API_KEY` → `:miosa` (preferred),
   `E2B_API_KEY` → `:e2b`, `VERCEL_TOKEN` → `:vercel`.
3. Otherwise `:host` (no sandbox).

`mode: required` composes with auto-mode: the dangerous-command circuit breaker
(below) still hard-blocks catastrophic commands in every tier, and everything
that survives the safety checks runs *inside the sandbox* rather than on the host.

---

## Dangerous-command circuit breaker

`OptimalSystemAgent.Agent.Safety.DangerousCommands` is a **non-bypassable**
hard blocklist wired as the **first** clause of the tool-execution boundary
(`Agent.Loop.ToolExecutor`), above the permission-tier gate and the auto-mode
`Guardian`. It applies in **every** permission tier — including `:full` /
bypass — and cannot be overridden by config or by the Guardian.

Distinction from the auto-mode policy:

- **`Safety.Rules` / `Classifier` / `Guardian`** — risk-tiered, *allowable*
  auto-mode policy. Verdicts (`:safe` / `:caution` / `:dangerous`) are enforced
  per permission tier, with a pause-after-N mechanism.
- **`Safety.DangerousCommands`** (circuit breaker) — the *never, under any
  circumstances* subset. Tier-independent, no counter, no allowlist, no toggle.

Always blocked (on shell tools — `shell_execute`/`shell`/`bash`/`run_command`/
`code_sandbox`/`repl` — and file-delete tools — `file_delete`):

- `rm -rf` targeting a broad root (`/`, `~`, `$HOME`, `/*`, `.`, a bare
  top-level system dir), incl. `\rm` alias / split-flag / path-prefixed bypasses.
- `git push --force` / `-f` / `+ref` to a protected branch
  (`main`, `master`, `production`, `prod`, `release`, `develop`, `staging`),
  or a bare force-push of the current branch.
- Fork bombs (`:(){ :|:& };:` and single-char variants).
- `dd` writing to a block device (`of=/dev/sd…`, `/dev/nvme…`, `/dev/disk…`).
- `mkfs` / filesystem creation on a device.
- `DROP DATABASE` / `DROP SCHEMA`; `DROP TABLE` / `TRUNCATE` on a prod identifier.
- Pipe-to-shell of downloaded content (`curl … | sh`, `wget … | sudo bash`).

`DangerousCommands.blocked?/1` is pure (`{:blocked, reason}` | `:ok`) — no I/O,
no state — accepting a tool-call map or a raw command/path string.

---

## Pool

`Sandbox.Pool` maintains a pool of warm sandbox instances per backend type. Configuration:

```elixir
config :optimal_system_agent,
  sandbox_pool_size: 4,          # max concurrent sandboxes
  sandbox_pool_overflow: 2       # allow up to 2 overflow instances
```

`Pool.acquire/1` returns a sandbox handle within `checkout_timeout_ms`. `Pool.release/1` returns it to the pool for reuse.

---

## Provisioner

`Sandbox.Provisioner` handles the creation of new sandbox instances for each backend:

- **Docker:** Calls `docker run` with the configured image and resource limits.
- **BEAM Task:** Spawns a supervised task with restricted capabilities.
- **WASM:** Initialises a WASM module instance.

Provisioning includes a readiness check before handing the instance to the pool.

---

## Registry

`Sandbox.Registry` maintains the map of active sandbox handles. Enables:

- Listing all running sandboxes.
- Forcefully terminating a sandbox by ID.
- Attaching metadata (session ID, tool call ID) to each sandbox for observability.

---

## Security

Sandboxes enforce these constraints regardless of backend:

- Execution timeout (kills the process/container on expiry).
- Memory limit (OOM kills the container/task).
- No network access (Docker `--network=none`, WASM no-network capability).
- No host filesystem access (Docker volume mounts excluded, BEAM task temp dir only).
- Resource limits prevent CPU starvation.

Additional shell-level security is enforced by the shell policy — see [security.md](security.md).

---

## Platform Sandboxes

`OsInstance.sandbox_id` and `OsInstance.sandbox_url` link an OS instance to a provisioned sandbox environment. These are set by the platform provisioning workflow after instance creation.

The Command Center API provides sandbox management:

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/command-center/sandboxes` | Provision a new sandbox |

---

## See Also

- [security.md](security.md) — Shell policy and command blocklist
- [../platform/instances.md](../platform/instances.md) — OS instance sandbox fields
