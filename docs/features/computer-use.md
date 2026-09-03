# Computer Use — Desktop & Browser Control

OSA's computer use tool gives agents the ability to see and interact with any desktop environment — local or remote. It follows the same adapter pattern used across OSA: a single tool interface backed by platform-specific implementations that are auto-detected at runtime.

## Architecture

```
computer_use.ex                     Tool interface (MiosaTools.Behaviour)
│                                   Validation, lazy GenServer start
│
├── server.ex                       GenServer — platform detection, dispatch,
│                                   AX tree cache, element refs, idle shutdown,
│                                   keyframe journal, action planning
│
├── adapter.ex                      Behaviour contract (10 callbacks)
│                                   + detect_platform/0, adapter_for/1
│
├── accessibility.ex                Tree parsing, ref assignment, diffing,
│                                   compact text formatting (~800 tokens/page),
│                                   spatial pruning of static regions
│
├── planner.ex                      Perceive → Plan → Execute → Verify loop
│                                   (inspired by MIT VLMFP SimVLM/GenVLM pattern)
│
├── keyframe.ex                     Post-action keyframe capture, trajectory
│                                   journal for reward evaluation and replay
│
└── adapters/
    ├── macos.ex                    screencapture, osascript, Python/Quartz
    ├── linux_x11.ex                maim/scrot, xdotool
    ├── linux_wayland.ex            grim, ydotool
    ├── remote_ssh.ex               SSH forwarding to remote Linux VMs
    ├── docker.ex                   docker exec/cp to containers
    └── platform_vm.ex              Firecracker microVMs via Sprites.dev API
```

## Research Foundation

This design incorporates techniques from three recent papers:

| Paper | Key Technique | How OSA Uses It |
|-------|--------------|-----------------|
| **ExeVRM** (USC/Amazon AGI, 2025) — Video-Based Reward Modeling for CUAs | STP (Spatial Token Pruning) + TTP (Temporal Token Pruning); keyframe extraction at 1 FPS; 40-60% token reduction | Accessibility tree = native STP (structured elements vs raw pixels). Tree diffing = native TTP (only changed elements sent). Keyframe journal captures post-action screenshots for trajectory evaluation. |
| **VLMFP** (MIT, 2026) — VLM-Guided Formal Planning | Two-stage: SimVLM (perceive + simulate) → GenVLM (plan in PDDL) → classical solver → execute; iterative refinement; ~70% success (2x baseline) | Planner module implements Perceive → Plan → Execute → Verify loop. Agent builds structured action plan before executing, verifies after each step, replans on deviation. |
| **ICRL** (NUS, 2025) — In-Context RL for Tool Use | Curriculum learning: few-shot examples during rollouts → gradual reduction → zero-shot autonomy; RL-only (no SFT needed) | Agent starts with worked examples of UI interactions in system prompt. As learning engine captures successful patterns (Layer 6), examples are replaced by learned skills. |

## How It Works

### 1. Platform Detection

When the GenServer starts (lazily, on first tool call), `Adapter.detect_platform/0` resolves the target platform in priority order:

| Priority | Check | Platform |
|----------|-------|----------|
| 1 | `config :optimal_system_agent, :computer_use_platform` is set | that value, verbatim |
| 2 | `:os.type() == {:unix, :darwin}` | `:macos` |
| 3 | `:os.type() == {:unix, :linux}` + `$WAYLAND_DISPLAY` | `:linux_wayland` |
| 4 | `:os.type() == {:unix, :linux}` + `$DISPLAY` | `:linux_x11` |
| 7 | `:os.type() == {:win32, _}` | `:windows` (not yet supported) |

`adapter_for/1` maps the platform atom to the concrete adapter module. The server verifies `adapter.available?()` before accepting commands.

### 2. Perceive → Plan → Execute → Verify (PPEV Loop)

Inspired by MIT's VLMFP, multi-step computer use tasks follow a structured loop instead of blind action-by-action guessing:

```
┌─────────────────────────────────────────────────────┐
│                    PPEV Loop                         │
│                                                      │
│  1. PERCEIVE                                         │
│     get_tree OR screenshot                           │
│     → structured understanding of current state      │
│                                                      │
│  2. PLAN                                             │
│     Given: goal + current state + history            │
│     → ordered list of actions to reach goal          │
│     → pre-check: does plan seem feasible?            │
│                                                      │
│  3. EXECUTE                                          │
│     Run next action from plan                        │
│     → capture keyframe (post-action screenshot)      │
│     → record in trajectory journal                   │
│                                                      │
│  4. VERIFY                                           │
│     get_tree diff OR screenshot comparison           │
│     → did the expected state change happen?           │
│     → if YES: continue to next action                │
│     → if NO: replan from step 2 with new state       │
│     → if STUCK (3x same failure): escalate to user   │
│                                                      │
└─────────────────────────────────────────────────────┘
```

This prevents the agent from blindly clicking through UIs. Each action is verified before proceeding, and the plan adapts when reality diverges from expectations.

### 3. Action Dispatch

All actions flow through the same path:

```
Agent calls tool "computer_use" with action + params
  → computer_use.ex validates params
  → ensures GenServer is running (lazy start)
  → GenServer.call to Server
  → Server dispatches to adapter callback
  → adapter executes platform-native command
  → keyframe captured (post-action screenshot)
  → trajectory journal updated
  → {:ok, result} | {:error, reason}
```

### 4. Idle Shutdown

The server shuts itself down after 10 minutes of inactivity. Each action resets the timer. This prevents resource leaks when computer use is intermittent.

## Available Actions

| Action | Parameters | Description |
|--------|-----------|-------------|
| `screenshot` | `region?` | Capture full screen or region `{x, y, width, height}` |
| `click` | `x, y` or `target` | Click at coordinates or element ref |
| `double_click` | `x, y` | Double-click at coordinates |
| `type` | `text` | Type a string (max 4096 bytes) |
| `key` | `text` | Press key combo: `"cmd+c"`, `"enter"`, `"ctrl+shift+v"` |
| `scroll` | `direction, amount?` | Scroll `up/down/left/right` by N units (default 3) |
| `move_mouse` | `x, y` | Move cursor without clicking |
| `drag` | `x, y, region` | Drag from `(x,y)` to `(region.x, region.y)` |
| `get_tree` | `force_refresh?` | Fetch accessibility tree with element refs |

## Token Efficiency: Spatial & Temporal Pruning

Informed by ExeVRM's spatiotemporal token pruning, OSA applies two layers of redundancy reduction to minimize tokens sent to the LLM:

### Spatial Pruning (STP) — Within Each Perception Step

| Method | Tokens/page | When Used |
|--------|------------|-----------|
| Raw screenshot (base64) | ~10,000+ | Fallback only (canvas, WebGL, no AX tree) |
| Accessibility tree (structured text) | ~800 | Default — native STP via structured elements |
| Pruned screenshot (region crop) | ~2,000-4,000 | Hybrid: tree + cropped screenshot of ambiguous area |

The accessibility tree is inherently spatially pruned — it only contains interactive elements, their roles, names, states, and bounding boxes. Static backgrounds, decorative images, and layout chrome are excluded by design.

When screenshots are necessary, region-based capture reduces the visual field to only the relevant area identified by the accessibility tree. This mirrors ExeVRM's STP which removes visually homogeneous regions (large static backgrounds, toolbars).

### Temporal Pruning (TTP) — Across Action Steps

After each action, instead of sending the full tree again:

```
+ [e5] button "New Button" (300,200)       # appeared
- [e2] link "Old Link" (100,50)            # disappeared
~ [e1] textfield "Email" moved (200,150) → (200,180)   # changed
```

Only the **diff** is sent to the LLM. This mirrors ExeVRM's TTP which removes tokens with cosine similarity > 0.9999 across consecutive frames. In practice, 70-90% of UI elements remain static between actions — the diff captures only what matters.

**Token budget per step:**
- First perception: ~800 tokens (full tree)
- Subsequent perceptions: ~50-200 tokens (diff only)
- Screenshot fallback: ~2,000-4,000 tokens (region crop)

## Element Refs — Structured Targeting

Instead of guessing coordinates from screenshots, the agent can:

1. Call `get_tree` to fetch the accessibility tree
2. Receive element refs like `e0`, `e1`, `e2`... assigned to every interactive element (buttons, links, text fields, checkboxes, etc.)
3. Call `click` with `target: "e3"` to click that element by ref

This is deterministic and reliable — no coordinate estimation errors.

### How Refs Are Assigned

The `Server` walks the accessibility tree and assigns sequential refs (`e0`, `e1`, ...) to every node whose role is interactive:

```
button, link, textfield, textarea, checkbox, radio, menuitem,
tab, slider, combobox, switch, toggle, searchfield, toolbar, ...
```

Each ref maps to the center coordinates of the element's bounding box. The ref map is cached for 5 seconds (configurable via `@tree_ttl_ms`).

### Compact Text Format

The `Accessibility` module formats the tree as compact text for LLM consumption:

```
[e0] button "Submit" (500,300)
[e1] textfield "Email" value="user@..." (200,150)
[e2] link "Home" (100,50)
  [e3] checkbox "Remember me" checked (200,400)
```

This uses ~800 tokens per page vs ~10,000+ for screenshots — a 5-13x cost reduction.

### Tree Diffing

After each action, the agent can call `get_tree` again. `Accessibility.diff_trees/2` computes incremental changes:

```
+ [e5] button "New Button" (300,200)       # appeared
- [e2] link "Old Link" (100,50)            # disappeared
~ [e1] textfield "Email" moved (200,150) -> (200,180)   # position changed
```

Only the diff is sent to the LLM, further reducing token usage.

## Keyframe Journal — Trajectory Recording

Every action automatically captures a post-action keyframe (screenshot). These are stored in a chronological journal:

```
~/.osa/trajectories/{session_id}/
  ├── journal.jsonl           # action log with timestamps
  ├── keyframe_001.png        # post-action screenshot
  ├── keyframe_002.png
  └── ...
```

Each journal entry records:

```json
{
  "step": 1,
  "timestamp_ms": 1710600000000,
  "action": "click",
  "params": {"target": "e3"},
  "tree_before": "hash_abc",
  "tree_after": "hash_def",
  "tree_diff": "+ [e5] button 'Save' (300,200)",
  "keyframe": "keyframe_001.png",
  "result": "ok"
}
```

### Uses

1. **Self-verification**: The PPEV loop uses keyframes to verify actions succeeded
2. **Reward evaluation**: Trajectory can be fed to ExeVRM-style models to judge task success
3. **Replay & debugging**: Full trajectory replay for debugging failed tasks
4. **Learning capture**: Successful trajectories become training data for the learning engine (Layer 6)
5. **Doom loop detection**: Repeated identical keyframes trigger the 3-strike guard from Layer 1

## Curriculum Learning for Computer Use

Following ICRL's insight that agents learn tool use better through curriculum (few-shot → zero-shot), OSA's computer use agent progresses through competence levels:

### Level 1: Guided (Initial)
- System prompt includes 2-3 worked examples of common UI interactions
- Examples show the full PPEV cycle: perceive tree → plan → click ref → verify diff
- Agent follows examples closely

### Level 2: Assisted (After pattern capture)
- Learning engine (Layer 6) captures successful interaction patterns
- Worked examples replaced by learned skills: "When you see a login form, fill email → password → click submit"
- Agent generalizes from patterns

### Level 3: Autonomous (Mature)
- Agent plans multi-step UI tasks from goal description alone
- Falls back to screenshot when tree is insufficient
- Records new patterns for future learning

This progression happens automatically through the SICA learning cycle — no manual intervention needed.

## Platform Adapters

### macOS (`adapters/macos.ex`)

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `screencapture` (ships with macOS) |
| Mouse | Python/Quartz via `osascript do shell script` — `CGEventCreateMouseEvent` |
| Keyboard | AppleScript `tell app "System Events" to keystroke/key code` |
| Key codes | 27 named keys (enter, tab, escape, F1-F12, arrows, etc.) |
| Accessibility | Stubbed — planned AXorcist integration |

**Requirements:**
- macOS (auto-detected)
- Accessibility API permission: System Settings → Privacy & Security → Accessibility

### Linux X11 (`adapters/linux_x11.ex`)

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `maim` (preferred) or `scrot` (fallback) |
| Mouse | `xdotool mousemove`, `click`, `mousedown/mouseup` |
| Keyboard | `xdotool type`, `xdotool key` |
| Scroll | `xdotool click` with buttons 4/5/6/7 |
| Accessibility | Stubbed — planned AT-SPI2 integration |

**Requirements:**
- Linux with X11
- `xdotool` installed
- `maim` or `scrot` for screenshots

### Linux Wayland (`adapters/linux_wayland.ex`)

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `grim` (full screen or region via `-g`) |
| Mouse/Keyboard | `ydotool` (requires `ydotoold` daemon) |
| Key codes | Linux input event names (`KEY_ENTER`, `KEY_LEFTMETA`, etc.) |

**Requirements:**
- Linux with Wayland (`$WAYLAND_DISPLAY` set or `$XDG_SESSION_TYPE=wayland`)
- `ydotool` + `ydotoold` running
- `grim` for screenshots

### Remote SSH (`adapters/remote_ssh.ex`)

Forwards all commands over SSH to a remote Linux machine. The agent controls the remote desktop as if it were local.

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `maim`/`grim` on remote, transferred via `scp` |
| Input | `xdotool`/`ydotool` via `ssh user@host "command"` |
| Auth | Public key or SSH agent (BatchMode=yes, no passwords) |
| Cleanup | Remote screenshots deleted after SCP transfer |

**Configuration:**

```elixir
config :optimal_system_agent, :computer_use_remote,
  host: "192.168.1.100",        # required
  port: 22,                      # default: 22
  user: "ubuntu",                # default: "root"
  key_path: "~/.ssh/id_rsa",    # optional (omit for SSH agent auth)
  remote_display: ":0",          # X11 DISPLAY on remote (default: ":0")
  remote_platform: :linux_x11   # :linux_x11 (default) | :linux_wayland
```

**Diagnostics:**

```elixir
RemoteSSH.test_connection()
# {:ok, %{connected: true, system: "Linux vm-1 5.15.0 ..."}}
```

### Docker (`adapters/docker.ex`)

Forwards commands into a running Docker container via `docker exec`. Designed for headless desktop containers (e.g., Anthropic's computer-use reference image with Xvfb + xdotool).

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `maim`/`scrot` inside container, `docker cp` to host |
| Input | `xdotool` via `docker exec container bash -c "DISPLAY=:1 ..."` |
| Container check | `docker inspect -f {{.State.Running}}` |
| Cleanup | Container screenshots deleted after `docker cp` |

**Configuration:**

```elixir
config :optimal_system_agent, :computer_use_docker,
  container: "osa-desktop",          # container name or ID (required)
  display: ":1",                     # DISPLAY inside container (default: ":1")
  screenshot_path: "/tmp/screenshots" # screenshot dir inside container
```

**Diagnostics:**

```elixir
Docker.test_connection()
# {:ok, %{connected: true, container: "osa-desktop", system: "Linux ... + /usr/bin/xdotool"}}
```

### Platform VM (`adapters/platform_vm.ex`)

Forwards commands into Firecracker microVMs managed by the Sprites.dev sandbox backend (`Sandbox.Sprites`). The VMs run Linux with Xvfb + xdotool.

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `maim` inside VM, base64-encoded and decoded on host |
| Input | `xdotool` via `Sprites.execute/2` |
| Transfer | Base64 over API (no SCP/docker cp needed) |
| VM management | Sprites.dev API (create, checkpoint, restore, destroy) |

**Configuration:**

```elixir
config :optimal_system_agent, :computer_use_vm,
  sprite_id: "abc123",    # Sprites.dev VM identifier (required)
  display: ":1"           # DISPLAY inside VM (default: ":1")
```

**Requirements:**
- `SPRITES_TOKEN` environment variable set
- Sprites.dev VM provisioned with Xvfb + xdotool

**Diagnostics:**

```elixir
PlatformVM.test_connection()
# {:ok, %{connected: true, sprite_id: "abc123", system: "Linux ...", preview_url: "https://..."}}
```

## Configuration

### Enable Computer Use

Computer use is gated by a config flag (default `false`):

```elixir
config :optimal_system_agent, :computer_use_enabled, true
```

### Platform Override

For local use, the platform is auto-detected from `:os.type()` and the display-server
environment variables. Remote/container/VM targets are **not** auto-detected from their
config blocks — select one explicitly:

```elixir
config :optimal_system_agent, :computer_use_platform, :docker      # or :remote_ssh, :platform_vm
```

then fill in the matching `:computer_use_docker` / `:computer_use_remote` /
`:computer_use_vm` block below.

> `:platform_vm` additionally requires an `OptimalSystemAgent.Sandbox.Sprites`
> backend module, which is not shipped in this repo. The adapter is wired up and
> degrades cleanly (`available?/0` returns `false`, calls return
> `{:error, :sprites_unavailable}`), but it cannot drive a VM until that backend
> exists.

## Security

### Input Sanitization

- **AppleScript** (macOS): Backslashes and double quotes are escaped before interpolation into AppleScript string literals.
- **Shell commands** (SSH, Docker, Platform VM): All user text is wrapped in POSIX single-quote escaping (`'...'\\''...'`), preventing command injection.
- **Key combos**: Validated against `[a-zA-Z0-9+\-_ ]` — rejects semicolons, backticks, dollar signs, quotes.
- **Text length**: Capped at 4096 bytes to prevent abuse.
- **Coordinates**: Must be non-negative integers.

### SSH Security

- `BatchMode=yes` — no interactive password prompts
- `ConnectTimeout=10` — fast failure on unreachable hosts
- `StrictHostKeyChecking=no` — convenience for VM/container workflows. Override for production.

### Permission Gating

- Safety level: `:write_destructive`
- Every action except `screenshot` and `get_tree` requires user confirmation through OSA's permission system
- Tool enabled by default on supported desktops. Set `OSA_COMPUTER_USE=false`
  to disable it for a managed or headless deployment.

### Keyframe Security

- Keyframes stored locally only (`~/.osa/trajectories/`)
- Auto-cleanup after 24 hours (configurable)
- No keyframes captured for sensitive windows (password managers, banking apps) when accessibility tree reports `role: password_field` in focus

## Workflow: How the Agent Uses Computer Use

### Accessibility-Tree-First (Preferred — PPEV Loop)

```
1. get_tree → structured element list with refs          (PERCEIVE)
2. Build action plan from goal + current state            (PLAN)
3. click(target: "e3") → interact by ref                  (EXECUTE)
4. get_tree → diff shows what changed                     (VERIFY)
5. If goal not met → replan from current state             (LOOP)
```

The accessibility tree approach is preferred because:
- 5-13x fewer tokens per perception step (ExeVRM STP principle)
- Deterministic targeting (no coordinate estimation errors)
- Incremental updates via diffing (ExeVRM TTP principle)
- Works without vision model capabilities
- Plans can be verified before execution (MIT VLMFP principle)

### Screenshot-First (Fallback)

```
1. screenshot → see the screen                            (PERCEIVE)
2. Identify UI element and estimate coordinates           (PLAN)
3. click(x, y) → interact                                (EXECUTE)
4. screenshot → verify result                             (VERIFY)
```

Used when accessibility tree is unavailable or sparse (canvas, WebGL, games, remote desktops without AT-SPI2).

### Hybrid Mode

```
1. get_tree → identify elements                           (PERCEIVE)
2. screenshot(region: element_bbox) → visual context      (PERCEIVE+)
3. Plan from both structured + visual data                (PLAN)
4. Execute action                                         (EXECUTE)
5. get_tree diff + optional region screenshot             (VERIFY)
```

Used when the tree provides structure but the agent needs visual context to make decisions (e.g., color-coded status indicators, charts, image content).

## Testing

49 tests in `test/tools/computer_use_test.exs` covering:

- Tool metadata (name, description, safety, parameters)
- Availability gating (config flag behavior)
- Action validation (missing/invalid actions)
- Screenshot region validation (negative, zero, incomplete)
- Click validation (coordinates vs target, negative values, non-integers)
- Type validation (empty, non-string, too long)
- Key combo validation (injection characters, quotes, backticks, dollar signs, length)
- Scroll validation (missing/invalid direction)
- Move mouse / drag validation
- AppleScript sanitization
- Key combo parsing (modifiers, case-insensitivity)
- Screenshot command generation (integration, macOS only)

Run with:

```bash
mix test test/tools/computer_use_test.exs
```

## Future Work

- **AXorcist integration** (macOS): Wire native Accessibility API for real tree data
- **AT-SPI2 integration** (Linux): D-Bus accessibility tree on X11 and Wayland
- **Windows adapter**: AutoHotkey or UI Automation API
- **Browser tab awareness**: Integrate with `browser` tool for coordinated web + desktop control
- **Vision fallback**: Auto-switch to screenshot mode when AX tree is unavailable or sparse
- **Action recording/replay**: Record interaction sequences for automation
- **ExeVRM integration**: Feed trajectory journals to reward model for automated task success evaluation
- **Curriculum refinement**: Tune few-shot → zero-shot progression based on task domain complexity
