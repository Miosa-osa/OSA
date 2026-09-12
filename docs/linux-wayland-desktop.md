# Linux Wayland native desktop pathway

The implementation and build contract are documented in [native/linux/ScreenShare/README.md](../native/linux/ScreenShare/README.md).
The helper uses XDG portal consent, PipeWire monitor capture, portal-authorized input, and an ephemeral loopback RFB listener.
It does not capture the XWayland root window or modify the user's desktop configuration.

## Integration handoff

Use `OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Wayland.start/1` only for a real Wayland user session.
Its successful handle is `%{port_ref: port, os_pid: pid, vnc_port: number}` and `stop/1` accepts that handle or its owning Port.
For the native executor's interface, `spawn/1` returns a `%Wayland{port: port, os_pid: pid, vnc_port: number}` and `kill/1` stops that owned helper.
Both `spawn/1` and `start/1` pass `--read-only` unless their resolved options contain `allow_input: true`.
The permission and grant integration is documented in [native desktop permissions](native-desktop-permissions.md).
Callers must allow the 125-second startup deadline for a human consent dialog and cancel the owning process on job cancellation.
They must connect to the returned loopback port, never a configured fixed VNC port.
Keep the portal helper's stdin attached to its owning OSA Port; EOF ends sharing.
The existing grant checks must happen before helper startup and before exposing the relay.

Shared `desktop.ex`, `controller.ex`, and readiness selection now route Wayland through this permission-aware adapter.
The Linux release lane now builds and stages the helper before OTP assembly and verifies the final tarball against that exact binary and its bundled runtime requirements.
The exact shared-code contract is recorded in [the Zeno handoff](../native/linux/ScreenShare/INTEGRATION-ZENO.md).
The helper's `--check` is a permission-free prerequisite probe, not a consent or successful capture signal.
Advertise Wayland desktop readiness only after a trusted helper and its runtime/session prerequisites pass that probe.
SSH/headless services must not borrow another user's D-Bus address, launch a hidden display, or bypass consent to make the check pass.

## Acceptance before enabling broadly

On an explicitly consenting Linux Wayland test desktop, verify the selected monitor appears in the MIOSA viewer and pointer/keyboard events affect only that selected, granted session.
Verify cancellation and denial produce no listener, revocation ends the viewer, and stopping OSA leaves no helper.
Verify HiDPI pointer alignment, keyboard/button release, monitor geometry changes, capture backend failure, and viewer disconnection.
Repeat against each supported compositor portal backend rather than treating Linux as one universal desktop implementation.
These live checks have not been performed in this slice.
