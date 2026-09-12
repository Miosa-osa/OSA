# Wayland integration contract for Zeno

Zeno owns `desktop.ex`, `readiness.ex`, and shared desktop selection integration.
This file is the handoff because this session has no agent-messaging tool; receipt has not been confirmed.
The Linux helper owner is changing only helper packaging scripts, Linux automated checks, and Linux-specific steps in the shared release workflow.

## Launch and cleanup

- `Wayland.spawn/0` returns `{:ok, %Wayland{port: port, os_pid: pid, vnc_port: number}}` for the native executor.
- `Wayland.kill/1` stops that handle.
- `Wayland.start/1` returns `{:ok, %{port_ref: port, os_pid: pid, vnc_port: number}}` for the controller.
- `Wayland.stop/1` accepts that handle or the Port directly.

Select this adapter for a real Linux Wayland user session, not merely Linux or a present XWayland `DISPLAY`.
Startup requires nonempty `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, and `DBUS_SESSION_BUS_ADDRESS`.
The helper waits for fresh monitor/input consent and a real frame before announcing its ephemeral loopback RFB port.
Allow 125 seconds for startup, retain its owning stdin, and cancel the owner on job cancellation.
Controller cleanup must dispatch Linux native Port handles to Wayland rather than the X11 PID cleanup path.
Both execution entry paths must retain existing grant checks before helper launch or relay exposure.

## Readiness

Resolve `osa-screen-capture-wayland` through `Desktop.HelperPath`, including its executable and hash-pinned override checks.
Run the trusted helper with `--check`, with an external deadline longer than its 5-second portal deadline.
Success is exit 0 and `READY=wayland_portal` on stdout.
Failure is nonzero and a diagnostic on stderr; missing shared libraries may fail before the helper starts.
This check inspects GStreamer factories and portal monitor/cursor/input properties without creating a capture session.
It is only a prerequisite check, never consent or a successful desktop QA result.
Never import another user's graphical-session environment to make a headless service pass.

## Packaging ownership

The Linux release lane will stage the freshly built helper into `priv/helpers` before `mix release` and verify the final tarball against that exact binary.
Runtime dependencies are documented alongside the staged helper; they are not silently installed on customer machines.
The existing release lane ships Linux x64 only; Linux aarch64 development builds do not imply a new public aarch64 OSA release lane.

Packaging scripts and the Linux-only automated workflow are implemented, with eight packaging tests passing against the real aarch64 binary.
The full Ubuntu 22.04 x64 build check has also passed: 11 native tests, eight packaging checks, Clippy, formatting, and optimized build.
See `VALIDATION.md` for the build evidence and remaining native QA limitations.
The separate VM/container follow-up is research only, in `docs/opencomputers-platform-runtime-design.md`.
It must not be interpreted as native desktop readiness or as a new VM backend implementation.
