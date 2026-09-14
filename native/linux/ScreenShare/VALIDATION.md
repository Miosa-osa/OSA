# Wayland slice validation receipt

## Completed

- Linux aarch64 release build passed in an isolated Debian Bookworm container using Rust 1.98 and GStreamer 1.22.0.
- `cargo test --locked`: 11 native tests passed.
- `cargo clippy --locked --all-targets -- -D warnings`: passed.
- Elixir `WaylandTest`: 5 tests passed using the real Port interface and hash-pinned executable fixtures.
- Rust formatting, scoped Elixir formatting, Bash syntax, and Git whitespace checks passed.
- Release executable `--version` returned `osa-screen-capture-wayland 0.1.0` without opening a portal session.

Release artifact SHA-256:

```text
79a317021cfb69e995b88ff2d08de6dc3ed8f75fae2c18da6bdd19aae5e61deb
```

The artifact is `/tmp/osa-wayland-target/release/osa-screen-capture-wayland` inside the task-owned Docker container `osa-wayland-build-20260912`.
It is an aarch64 artifact, not an x86_64 binary or a published OSA release.
The container-local target directory was used after the shared-filesystem release build failed to resolve an intermediate `toml_edit` artifact.
The fresh container-local build completed successfully.

## RED/GREEN evidence

The initial Elixir user-session test failed because the Wayland adapter did not exist, then passed after implementation.
The initial native frame and format tests failed because their modules did not exist, then passed after implementation.
The unknown-argument test reproduced exit code 1 instead of the required usage rejection code 64, then passed after strict argument dispatch was added.
The TCP viewer test reproduced a connection reset when a client advertised Tight without explicitly listing Raw, then passed after implementing the mandatory RFB raw fallback.

## Not verified or changed

No actual desktop capture, consent interaction, input injection, deployment, or new PR occurred in this slice.
No XWayland root capture, synthetic production framebuffer, persistent portal token, GNOME global setting, or permission bypass was added.
Live GNOME/KDE consent, denial, revocation, capture, HiDPI input, lock/unlock, and monitor changes need explicit opt-in verification.
The full OSA suite was not run here.
Shared desktop routing, controller selection/cleanup, and readiness advertisement remain integration-owner work.
Linux release packaging has since been wired into the existing release workflow with exact-artifact verification.
The full OTP release job has not been executed locally or dispatched remotely as part of this slice.
Existing unrelated files in the shared worktree were preserved.

## Integration acceptance

Both executor and controller entry paths must select Wayland for a real Wayland user session and call its matching cleanup interface.
The native executor uses `Wayland.spawn/0` and `kill/1`; the controller uses `start/1` and `stop/1`.
Do not mark the mode ready merely because `WAYLAND_DISPLAY` or a helper file exists.
Use the trusted helper's bounded `--check` for prerequisite probing, and still require fresh consent before opening a viewer.
Allow the helper's human-consent startup deadline and preserve owner stdin so cancellation closes sharing.

## Packaging extension

Eight packaging tests pass against the real Linux aarch64 release binary.
The combined `test-build.sh` completed successfully with Clippy, formatting, all 11 native tests, the optimized release build, and all six packaging tests.
Two additional guards subsequently passed: an absent built helper must not create a staging destination, and a relative target directory must be rejected.
They verify successful staging from an unrelated working directory and reject missing, stale, linked, wrong-architecture, and undocumented helper artifacts.
The archive used by these tests contains a real helper in an OTP-shaped application directory; it is not a full OTP release build.
The Linux x64 release job now verifies the actual assembled OTP tarball before artifact upload.
The new Linux-only automated workflow runs build, native protocol tests, lint, and packaging checks without starting capture.
No generated release files or binary assets were manually edited or committed.
Agent messaging is unavailable in this session, so `INTEGRATION-ZENO.md` is a shared-worktree handoff and does not claim Zeno's acknowledgment.
Actionlint passed the new Linux workflow and structural validation of the shared release workflow.
Full ShellCheck-backed validation of the shared release workflow reports a pre-existing SC2015 warning in the macOS helper freshness check; the same warning was reproduced against `HEAD` before these changes.
That unrelated macOS step was preserved under the Linux-only ownership constraint.

## Ubuntu 22.04 x64 baseline

The complete `test-build.sh` passed in an isolated emulated x86_64 Ubuntu 22.04 container with Rust 1.98.0, GStreamer 1.20.3, and glibc 2.35.
Formatting, Clippy with warnings denied, all 11 native tests, the optimized release build, and all eight real-binary packaging checks passed.
The package tests verify the ELF x64 machine identity, not merely the filename.
The helper's `--version` returned `osa-screen-capture-wayland 0.1.0`.
The artifact is `/tmp/wayland-target/release/osa-screen-capture-wayland` inside `osa-wayland-jammy-x64-20260912`.

```text
370f895c0c353ba98bde855fb52cd004154c264c1e9bc2233426856640befe11
```

This verifies build compatibility and automated behavior on the release distribution baseline, not native desktop capture or a completed OTP release workflow.
