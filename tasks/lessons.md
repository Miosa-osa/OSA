# Lessons Learned

Hard-won debugging insights and fixes. Search here before debugging anything.

---

## CLI-001: Duplicate Input Lines in REPL (Feb 2026)

**Symptom**: Every line typed in `mix osa.chat` appeared twice. Empty Enter presses produced duplicate prompts.

**Root cause (4 layers)**:

| Layer | What broke | Why |
|-------|-----------|-----|
| `:os.cmd` stty | `stty raw -echo` silently failed | `:os.cmd` redirects subprocess stdin to a pipe. `stty` couldn't find the terminal. Even `< /dev/tty` redirect inside the subshell was unreliable. |
| OTP 28 prim_tty | Software echo doubled our output | `IO.write` routes through group_leader -> user_drv -> prim_tty. In OTP 26+, prim_tty does its own line-state tracking and software echo. Our rendered line went through prim_tty, which re-processed it. |
| No error detection | Proceeded into raw readline with cooked terminal | `set_raw_mode` returned void. Code assumed it worked. Terminal stayed in cooked+echo mode: hardware echo + our redraw = double. |
| Double goodbye | `cmd_exit` returned `"goodbye"` text | `handle_command` printed the text AND `handle_action(:exit)` called `print_goodbye()`. Two writes. |

**Fix**:

1. **stty via Port.open** — `Port.open({:spawn_executable, stty_path}, args: ["-f", "/dev/tty", "raw", "-echo"])`. No shell, no stdin pipe. `-f` (macOS) / `-F` (Linux) operates on the device directly.

2. **All readline I/O bypasses Erlang** — Open `/dev/tty` with `[:read, :write, :raw, :binary]`. Use `:file.write(tty, data)` for all output during readline. Never touches `IO.write` -> group_leader -> prim_tty.

3. **Graceful fallback** — `set_raw_mode` returns `:ok` / `:error`. On failure, falls back to `IO.gets` instead of rendering into a cooked terminal.

4. **Empty string for exit** — `cmd_exit` returns `{:action, :exit, ""}` so `print_response` is a no-op.

**Files**: `channels/cli/line_editor.ex`, `commands.ex`

**Lesson**: On OTP 26+, NEVER use `IO.write` for custom terminal rendering during raw mode. Erlang's prim_tty will interfere. Write directly to a `/dev/tty` fd. And NEVER use `:os.cmd` for stty — use `Port.open` with `:spawn_executable`.

---

## BUILD-001: NIF Compilation Blocks All Compilation (Feb 2026)

**Symptom**: `mix compile` fails entirely because Rustler NIF requires rustc >= 1.91 but system has 1.88.

**Root cause**: `skip_compilation?` in `nif.ex` defaulted to `false`, requiring Rust compilation even though all NIF functions have pure-Elixir fallbacks.

**Fix**: Inverted default — now skips unless `OSA_SKIP_NIF=false` is explicitly set. The NIF is optional.

**File**: `nif.ex`

**Lesson**: Optional native code should be opt-IN for compilation, not opt-out.

---

## BUILD-002: Missing Function Stubs Block Compilation (Feb 2026)

**Symptom**: `commands.ex` references `cmd_whatsapp/2` and `cmd_channels/2` in the command table but the function bodies don't exist.

**Root cause**: Command table entries were added before implementations.

**Fix**: Added full implementations (linter expanded stubs into proper channel management commands).

**Lesson**: Command table is compile-time validated via `&function/arity` captures. Every entry needs a function body or compilation fails.

---

## Template for New Entries

```
## CATEGORY-NNN: Title (Mon YYYY)

**Symptom**: What the user sees.

**Root cause**: Why it happens (be specific — name modules, OTP versions, OS behavior).

**Fix**: What changed and why.

**Files**: Which files were modified.

**Lesson**: The one-liner future-you needs to remember.
```

Categories: `CLI`, `BUILD`, `PROVIDER`, `AGENT`, `SWARM`, `CHANNEL`, `PERF`, `SECURITY`
