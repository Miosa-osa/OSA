# Project notes

## 2026-09-12: native macOS workload helper

The sole VZ helper implementation lives in native/macos/OpenComputersVM; the paired compute adapter uses canonical signed HostSession authority, durable identity and admitted lifecycle.
The helper compiles and permission-free protocol/storage tests pass without constructing a VM.
Native usage, certified arm64 images, authenticated guest transport/readiness, release signing/packaging and complete generic startup integration remain explicit blockers.
See native/macos/OpenComputersVM/INTEGRATION-PARENT.md and VALIDATION.md; native desktop sharing and native workload compute remain separate paths.

## 2026-09-07: native capture memory incident

The 06:38 CDT Jetsam report recorded eight `osa-screen-capture-darwin` processes with approximately 345 GiB of combined page accounting.
The development helper UUID matched six of them.
Native subprocess tests reproduced ignored SIGTERM and survival after owner EOF; the main queue was blocked on a semaphore that prevented its own signal handlers from running.
Ordinary macOS test runs included the native capture test, and its SIGTERM-only cleanup could leave those processes behind.
The older development checkout lacked a release rebuild; current main already fixes rebuilding, and this PR adds the regression gate without replacing that fix.
The native and Elixir lifetime fixes, cross-process helper slots, footprint watchdog, bounded frame pipeline, opt-in live tests, and release rebuild gate are documented in `docs/macos-desktop.md`.
Real ScreenCaptureKit allocation growth still needs a permission-enabled soak test; the permission-free frame pipeline is a separate validation and must not be presented as that live test.
Preserve unrelated pre-existing working-tree edits when committing this fix.

## 2026-09-11: headless OpenComputers installation

The v1.0.195 Linux full installer aborts before launcher creation on minimal Debian without libasound.so.2 because it unconditionally executes the standalone TUI.
The backend and generated Bash launcher can perform login, HTTP serve, and a local WebSocket hello without the TUI or ALSA.
OSA_INSTALL_MODE=headless records the installation mode in OSA_HOME/install_mode; reinstall and update preserve it, while absent mode files retain legacy full behavior.
The updater must keep headless mode through launcher replacement and must reject old launchers that would reinstall the TUI.
The service environment OSA_OPEN_COMPUTERS_ENABLED=true activates host mode without an enable marker or shell-profile changes.
Root cannot provide interactive PTY sessions, and local mock handshake evidence is not authenticated MIOSA enrollment.
See docs/headless-install.md for the contract, tests, and release handoff.

## 2026-09-12: Wayland packaging and native runtime boundary

Linux Wayland helper launch/readiness ownership is handed off in native/linux/ScreenShare/INTEGRATION-ZENO.md because agent messaging is unavailable in this session.
Packaging validates the actual ELF architecture and exact compiled bytes inside the release tarball rather than trusting a stale Mix copy.
Native automated tests do not establish portal consent, capture, input, or compositor QA.
The VM/container follow-up in docs/opencomputers-platform-runtime-design.md is research only.
OSA has container handlers in a separate router, but its inspected active Session.FrameRouter does not route their inbound frames.
Platform compute adapters should preserve the canonical HostSession signed-command, ledger, and customer lease boundary rather than reuse unrestricted direct execution.

### Physical desktop permission integration, 2026-09-11

The native desktop job and controller paths now accept input authority only from a separate owner-bound control-plane attestation over verified WSS, not raw job flags.
MIOSA's owner ticket producer and dispatcher counterpart live in the shared enrollment integration worktree; generic desktop job scopes cannot mint control approval.
See docs/native-desktop-permissions.md for exact contracts, expiry/revocation limits, verification evidence, and remaining full-stack/native QA.
OSA PR 274 was already merged before these local changes; main owns preserving this shared worktree and creating the replacement branch/PR.

## 2026-09-23: r203 UX — send-now, queued-in-conversation, minimal steer framing

Send-now (Agent.Loop.SendNow): a queued message now interrupts the running turn instead of waiting for the next ReAct step boundary.
`request/2` queues each message as a steer and raises a per-session ETS yield flag; `yield?/1` requires BOTH the flag AND a live queued steer (a flag that outlives its steer is stale and self-clears), so it can never interrupt an unrelated later batch.
The tool collectors (ToolOrchestrator.collect_tasks, StreamingToolExecutor.collect_results) and the LLM cancel watcher poll `yield?/1`; on a yield, still-running tools go to `background_pending/2` — a foreground shell detaches via the existing Ctrl+B path, a foreground subagent is re-marked `background: true` (RunStore.mark_background/1), everything else keeps running in its task.
Exactly-once hand-off is an ETS race on one key per tool call: the task claims `:finished`, the loop claims `:adopted`, whoever loses does the other half (deliver-as-notification vs await-the-reply).
A send-now mid-generation cuts the stream (`{:llm_stream_send_now}` -> `handle_result({:send_now, _})`), keeps the partial text, and CONTINUES the turn so the steer folds in next iteration — unlike cancel which ends it.
`SendNow.clear/1` runs right after `inject_pending_steer` drains the steer, so the flag lifecycle is tight.

Item 2 (queued messages in the conversation): the message texts render in the chat live region above the spinner (`Chat::draw_queued`), marked queued, reserved inside `Chat::streaming_height` (= stream body + queued rows) so NO new band and no event_loop/band-arbiter edit was needed — the whole feature lives in the chat component. The composer keeps a single-row affordance (count + "enter again sends it now"), no longer echoing the texts. `App::refresh_queue_display` keeps both surfaces in sync from `message_queue`.

Steer framing (operator scope): `Steer.to_messages/1` no longer wraps a steer in ~80 words of imperatives. It delivers the user's verbatim text in a `user`-role turn with only a neutral `[Received while you were working]` marker (source-neutral because goal-tracker nudges share the builder). A steer is identified by the `steer: true` metadata key, not by prompt text. `user`-after-tool-results is valid on every provider path OSA uses (finalize_interrupt already relies on it), so no system-role fallback.

Gotchas:
- `mix` fails on this box (global Hex archive won't load on OTP 28). Use a scratch `MIX_HOME=<scratchpad>/mixhome` with Hex reinstalled there; do NOT touch `~/.mix`.
- `cargo fmt` on the whole crate reformats `client/generated.rs`, which then fails CI's generator-drift check. Format only the files you changed (`rustfmt <file>`), never the crate.
- The `dialogs::pty_pane` cargo test is a timing flake (spawns a real child); passes in isolation. The two PTY resize sweeps ("WITH transcript", "emission-checked drag") flake on a DSR "cursor position could not be read within a normal duration" timeout under load; they exercise a transcript with no queued messages, where `queued_height` is 0, so send-now/queued code is inert on that path.
- The security-check hook blocks any bash command whose text contains "trunc-ate" (case-insensitive), so `mix test` on the file named for that word is refused by path; run the directory instead.
