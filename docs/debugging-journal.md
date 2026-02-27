# Debugging Journal

Post-mortems for every significant bug fixed in OSA. Each entry documents the symptom, root cause chain, fix, and the lesson so we never debug the same thing twice.

---

## How to Use This Doc

**Searching**: Ctrl+F the symptom you're seeing. Keywords are bolded in each entry.

**Adding entries**: Copy the template at the bottom. Use the next sequence number for the category.

**Categories**: `CLI` `BUILD` `PROVIDER` `AGENT` `SWARM` `CHANNEL` `PERF` `SECURITY`

---

## CLI-001: Duplicate Input Lines in REPL

**Date**: 2026-02-27
**Severity**: Critical (blocks all CLI usage)
**Versions**: Elixir 1.19.5, OTP 28, macOS Darwin 25.2

### Symptom

Every line typed in `mix osa.chat` appeared **twice**. Pressing Enter on an empty line produced duplicate `❯` prompts. Output like "goodbye" also doubled.

```
❯ Hello
❯ Hello          ← duplicate
  ⠋ Thinking…

❯                ← empty Enter
❯                ← duplicate prompt
```

### Root Cause (4 layers)

This was not one bug — it was four independent issues stacking on top of each other.

#### Layer 1: `:os.cmd` silently fails stty

`:os.cmd/1` spawns a subprocess with **stdin redirected to a pipe**. When we ran:

```elixir
:os.cmd(~c"stty raw -echo")
```

`stty` couldn't find a terminal on stdin. It exited silently (no error). The terminal stayed in **cooked mode with echo ON**. Even adding `< /dev/tty` inside the command string was unreliable because the redirect happened inside a subshell with unpredictable fd setup.

**Evidence**: Running `stty -g` via `:os.cmd` returned "stdin isn't a terminal".

#### Layer 2: OTP 28 prim_tty software echo

In OTP 26+, the Erlang shell replaced the old `user` module with `prim_tty` — a native terminal handler that does its own **software echo** and **line-state tracking**. When our LineEditor wrote output via `IO.write`:

```
IO.write → group_leader → user_drv → prim_tty → terminal
```

`prim_tty` intercepted the output, tracked it as "current line content", and could re-echo or re-render it. Even with hardware echo disabled via stty, prim_tty's software processing doubled the display.

This is why switching from `/dev/tty` writes to `IO.write` (attempted fix #2) didn't help — both paths had a duplication source.

#### Layer 3: No stty error detection

`set_raw_mode` returned void (the `:os.cmd` return value was ignored). The code assumed raw mode was active and proceeded to render lines that the terminal would also echo. No fallback path existed.

#### Layer 4: Double "goodbye" on /exit

`cmd_exit` returned `{:action, :exit, "goodbye"}`. The CLI's `handle_command` function:
1. Called `print_response("goodbye")` — first print
2. Called `handle_action(:exit)` → `print_goodbye()` — second print

### Fix

**File: `channels/cli/line_editor.ex`**

1. **Port-based stty** — replaced `:os.cmd` with `Port.open({:spawn_executable, stty_path})`. Runs the stty binary directly (no shell, no pipe). Uses `-f /dev/tty` (macOS) or `-F /dev/tty` (Linux) to target the device explicitly:

```elixir
Port.open(
  {:spawn_executable, exe},
  [:binary, :exit_status, :stderr_to_stdout,
   args: ["-f", "/dev/tty", "raw", "-echo"]]
)
```

2. **Direct /dev/tty I/O** — opened `/dev/tty` with `[:read, :write, :raw, :binary]`. ALL readline output uses `:file.write(tty, data)` instead of `IO.write`. This completely bypasses the Erlang IO pipeline (group_leader → user_drv → prim_tty):

```elixir
defp tty_write(tty, data), do: :file.write(tty, data)
defp redraw(state) do
  tty_write(state.tty, "\r\e[2K#{state.prompt}#{Enum.join(state.buffer)}")
end
```

3. **Graceful fallback** — `set_raw_mode` returns `:ok | :error`. On failure, falls back to `IO.gets` instead of entering the raw readline loop.

4. **Empty exit string** — `cmd_exit` returns `{:action, :exit, ""}`.

### Lesson

> On OTP 26+, **never** use `IO.write` for custom terminal rendering during raw mode — prim_tty will interfere. Write directly to a `/dev/tty` fd via `:file.write/2`. And **never** use `:os.cmd` for stty — use `Port.open` with `:spawn_executable`.

### Debugging Timeline

| Attempt | Approach | Result |
|---------|----------|--------|
| 1 | Clear raw-mode line before stty restore, re-display via IO | Still doubled |
| 2 | Route all output through `IO.write`, `/dev/tty` read-only | Still doubled |
| 3 | Add `< /dev/tty` redirect to `:os.cmd` stty calls | Still doubled |
| 4 | `Port.open` + `-f /dev/tty` for stty, direct `:file.write` for all output | **Fixed** |

---

## BUILD-001: NIF Compilation Blocks Everything

**Date**: 2026-02-27
**Severity**: High (blocks `mix compile`)
**Versions**: rustc 1.88.0, Rustler 0.37.2

### Symptom

`mix compile` fails with Rust compilation errors. Rustler 0.37.2 requires rustc >= 1.91 but the system has 1.88.0.

### Root Cause

`skip_compilation?` in `nif.ex` defaulted to `false`:

```elixir
skip_compilation?: System.get_env("OSA_SKIP_NIF", "false") == "true"
```

This forced Rust NIF compilation even though every NIF function has a pure-Elixir fallback (`safe_count_tokens/1`, `safe_calculate_weight/1`, `safe_word_count/1`).

### Fix

Inverted the default — NIF compilation is now opt-in:

```elixir
skip_compilation?: System.get_env("OSA_SKIP_NIF", "true") != "false"
```

### Lesson

> Optional native code should default to **skip** (opt-in for compilation), not require (opt-out). If all functions have Elixir fallbacks, the NIF is a performance optimization, not a requirement.

---

## BUILD-002: Missing Command Stubs

**Date**: 2026-02-27
**Severity**: High (blocks `mix compile`)

### Symptom

`commands.ex` won't compile — references to `&cmd_whatsapp/2` and `&cmd_channels/2` in the command table, but no function bodies exist.

### Root Cause

The command table uses compile-time function captures (`&function/arity`). Entries were added before implementations were written.

### Fix

Added full implementations for both commands (channel management with connect/disconnect/status/test subcommands, WhatsApp Web with QR code connect flow).

### Lesson

> The command table in `commands.ex` is **compile-time validated**. Every `{name, desc, &func/2}` tuple needs a corresponding `defp func/2` or compilation fails. Add the function body before (or at the same time as) the table entry.

---

## Template

```markdown
## CATEGORY-NNN: Short Title

**Date**: YYYY-MM-DD
**Severity**: Critical | High | Medium | Low
**Versions**: (relevant runtime/OS versions)

### Symptom

What the user sees. Include terminal output if possible.

### Root Cause

Why it happens. Be specific — name modules, OTP internals, OS behavior.

### Fix

What changed. Show before/after code if it helps.

### Lesson

> One-liner that future-you needs. Bold the key constraint.
```
