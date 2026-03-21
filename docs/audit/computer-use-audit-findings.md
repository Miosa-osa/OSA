# Computer Use System — Audit Findings

**Agent**: OSA Agent (Claude Code session)
**Date**: 2026-03-13
**Scope**: `lib/optimal_system_agent/tools/builtins/computer_use/` (6 adapters, server, accessibility, shared)
**Method**: 7-agent parallel audit + manual review + compile + test verification

---

## Critical Bugs Found & Fixed

### 1. get_tree State Loss (CRITICAL)
- **File**: `computer_use.ex` + `server.ex`
- **Bug**: `dispatch_action("get_tree")` fetched the accessibility tree but discarded the updated state (cached tree, element refs, timestamp). Next `click` with a target ref would always fail with "element ref not found".
- **Root cause**: `dispatch_action` returns only the result, not the updated state. The `get_tree` action needs to update GenServer state.
- **Fix**: Route `get_tree` through dedicated `ComputerUseServer.get_element_tree/1` GenServer call that properly returns `{result, new_state}` in `handle_call`.

### 2. Duplicate Tree Walking (~60 lines, MAJOR)
- **File**: `server.ex`
- **Bug**: `walk_tree/3`, `interactive?/1`, `element_center/1` were copy-pasted from `accessibility.ex` with divergent behavior:
  - Only 8 interactive roles (vs 18 in accessibility.ex)
  - String-keyed coords (vs atom-keyed in accessibility.ex)
  - O(n^2) child accumulation with `++`
- **Fix**: Deleted duplicate functions. `assign_element_refs/1` now delegates to `Accessibility.assign_refs/2` with a key-type conversion bridge (`%{x: x, y: y}` -> `%{"x" => x, "y" => y}`).

### 3. TOCTOU Race in ensure_server_started (MODERATE)
- **File**: `computer_use.ex`
- **Bug**: `Process.whereis(__MODULE__)` check followed by `start_link()` had a race window where another process could start the server between check and start.
- **Fix**: Removed the `whereis` check. Just call `start_link()` and handle `{:error, {:already_started, _pid}}` — idempotent and race-free.

---

## Code Duplication Found & Fixed

### 4. ~280 Lines Across 4 xdotool Adapters (MAJOR)
- **Files**: `linux_x11.ex`, `docker.ex`, `remote_ssh.ex`, `platform_vm.ex`
- **Duplicated code**: `@key_map` (57-entry map), `parse_key_combo/1`, `scroll_button/1`, `shell_escape/1`, `ensure_screenshot_dir/0`
- **Fix**: Extracted `ComputerUse.Shared` module (~120 lines). All 4 adapters now delegate to it.

---

## Security Vulnerabilities Found & Fixed

### 5. AppleScript Newline Injection (HIGH)
- **File**: `adapters/macos.ex`
- **Bug**: `sanitize_for_applescript/1` did not escape `\n` or `\r`. User-controlled text in `type_text/1` could inject AppleScript commands via newline characters.
- **Fix**: Added `\n` -> `\\n`, `\r` -> `\\r`, `\0` -> `""` sanitization.

### 6. Null Byte in Shell Escape (MODERATE)
- **File**: `shared.ex` (previously in each adapter's `shell_escape/1`)
- **Bug**: Null bytes (`\0`) could bypass single-quote shell escaping on some shells.
- **Fix**: Strip null bytes before escaping: `String.replace(text, "\0", "")`.

### 7. Key Combo Token Validation (LOW)
- **File**: `shared.ex`
- **Bug**: No validation that parsed key combos contained only safe characters before interpolation into shell commands.
- **Fix**: Added `validate_combo_tokens/1` with `~r/\A[a-zA-Z0-9_+]+\z/` pattern.

---

## Architecture Observations (No Fix Needed)

### 8. Accessibility Tree Not Implemented on macOS
- **File**: `adapters/macos.ex:184`
- **Status**: Returns `{:error, "not yet implemented"}`. Comment says "AXorcist integration planned".
- **Impact**: macOS users fall back to screenshot-based inspection. Not a bug — documented limitation.

### 9. Adapter Detection Priority
- **File**: `adapter.ex`
- **Order**: Platform VM -> Docker -> SSH -> local OS (macOS -> Wayland -> X11)
- **Status**: Correct. Remote/sandboxed environments should take priority over local.

### 10. Idle Shutdown Timer
- **File**: `server.ex:19`
- **Status**: 10-minute idle timeout with `Process.send_after`. Timer properly cancelled on each action and rescheduled. Clean implementation.

---

## Test Results
- **49/49 tests passing** after all fixes
- **`mix compile`**: Clean, no warnings
- **Coverage areas**: All 9 actions (screenshot, click, double_click, type, key, scroll, move_mouse, drag, get_tree), validation, element refs, adapter selection

---

## Files Modified
| File | Change | Lines Changed |
|------|--------|--------------|
| `computer_use.ex` | get_tree routing, TOCTOU fix | ~15 |
| `server.ex` | Delegate to Accessibility, fix interactive roles, drag params | ~80 removed, ~15 added |
| `shared.ex` | **NEW** — extracted shared utilities | ~120 |
| `adapters/macos.ex` | Sanitize newlines/nulls in AppleScript | ~5 |
| `adapters/linux_x11.ex` | Delegate to Shared | ~60 removed, ~5 added |
| `adapters/docker.ex` | Delegate to Shared | ~70 removed, ~5 added |
| `adapters/remote_ssh.ex` | Delegate to Shared | ~70 removed, ~5 added |
| `adapters/platform_vm.ex` | Delegate to Shared | ~70 removed, ~5 added |

**Net result**: ~350 lines removed, ~165 lines added = **~185 lines net reduction**

---

## Broader Codebase Issues Identified (Not Fixed — Separate Scope)

### A. Shim Layer Confusion
- `lib/miosa/shims.ex` — 756 lines, 28 module definitions creating `Miosa*` aliases
- 90+ call sites use shims instead of real `OptimalSystemAgent.*` modules
- Risk: Circular delegation (e.g., `Events.Classifier` <-> `MiosaSignal.Classifier`)

### B. macOS Finder Duplicate Files
- 10 files with " 2" suffix in git (`.svelte`, `.exs`, binary)
- Should be deleted — they're Finder copy artifacts

### C. Namespace Confusion
- Three namespaces coexist: `OptimalSystemAgent.*`, `Miosa*` (shims), `MiosaTools/MiosaSignal/etc.` (vendored packages)
- Makes codebase feel "spaghetti coded" — unclear which is canonical

### D. Missing Developer Guide
- No single document mapping "how to add X" for agents, tools, screens, skills
- Extension patterns exist and are clean, but undocumented
