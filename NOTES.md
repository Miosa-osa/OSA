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

## 2026-10-08: MIOSA AI Gateway platform mode

A MIOSA sandbox run sets MIOSA_AI_GATEWAY_URL and MIOSA_AI_GATEWAY_KEY, plus OSA_DEFAULT_PROVIDER=openai, OPENAI_BASE_URL and OPENAI_API_KEY carrying the same values (miosa-compute `Engine.AgentAccounts.Injection.osa_payload/2`).
OSA already honored OPENAI_BASE_URL before this change, so the full platform contract worked; the gap was that MIOSA_AI_GATEWAY_* alone did nothing.
Worse, the sandbox identity layer also sets MIOSA_API_KEY to the sandbox's platform identity token, so a gateway-only environment auto-selected `:miosa` and sent that token to optimal.miosa.ai.
config/runtime.exs now resolves the OpenAI-compatible URL and key as one pair: OPENAI_BASE_URL first, else the gateway pair, and the gateway outranks MIOSA_API_KEY in provider auto-detection.
An explicit OSA_DEFAULT_PROVIDER still wins.
The gateway serves Chat Completions only, so `OpenAICompatProvider.transport/2` keeps Responses-only models (gpt-6-astra) on Chat Completions when `:openai` dials the gateway.
Onboarding.first_run?/0 and bin/osa skip the setup wizard when the gateway pair is present, because a platform-managed run has nothing to configure and must not block on stdin.
config.exs gives openai/anthropic/openrouter/surplus a compiled `:<provider>_model`, which outranks `:default_model`, so OPENAI_MODEL and OSA_MODEL were silently ignored for them; runtime.exs now sets `:<provider>_model` from `<PROVIDER>_MODEL`, else from OSA_MODEL for the selected provider.
SessionTitler no longer picks OpenAI's catalog small model (gpt-4o-mini) when `:openai` dials the gateway; titles use the session's own model.
Verified end to end with a locally built release (`osagent serve`) against a stub gateway: requests hit `<gateway>/chat/completions` with `Bearer <run key>` and the OSA_MODEL model.
Tests that read runtime.exs as :prod must neutralize the ~/.osa/.env loader, because HOME is fixed at VM start and a developer's OSA_DEFAULT_PROVIDER would leak in; see test/providers/miosa_gateway_test.exs.
