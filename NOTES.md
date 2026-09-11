# Project notes

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
