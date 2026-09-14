# Linux Wayland screen sharing helper

This is a real portal/PipeWire-to-RFB adapter, not an XWayland root-window capture or a synthetic framebuffer.
It is a separate Linux binary named `osa-screen-capture-wayland`.
The OSA adapter is `Executor.Direct.Desktop.Wayland`.

## Build

Build on Linux with Rust 1.88 or newer and GStreamer development libraries.
Use the committed Cargo.lock with `--locked`.
For Ubuntu 24.04, build prerequisites are `build-essential pkg-config libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev`.
Runtime prerequisites include `gstreamer1.0-pipewire gstreamer1.0-plugins-base`, PipeWire, a running user D-Bus session, and a compositor portal backend implementing both RemoteDesktop and ScreenCast.
Installing the generic `xdg-desktop-portal` package alone does not establish those capabilities.

```sh
bash native/linux/ScreenShare/build.sh
cargo test --locked --manifest-path native/linux/ScreenShare/Cargo.toml
cargo clippy --locked --manifest-path native/linux/ScreenShare/Cargo.toml --all-targets -- -D warnings
```

The build script does not install packages, copy over a running helper, or modify desktop configuration.
The Linux release job now runs `build.sh` and `stage.sh` before OTP assembly, then `verify-package.sh` on the final Linux tarball.
Staging bundles the matching architecture binary at `priv/helpers/osa-screen-capture-wayland` and its runtime prerequisites at `priv/helpers/osa-screen-capture-wayland.runtime.md`.
Archive verification requires a regular executable of the correct ELF architecture with bytes identical to the current build, plus the current runtime document.
The helper is distributed inside the existing checksummed OTP tarball, not through a separate unsigned download.
Only Linux-specific steps of the shared release workflow were changed; desktop routing/readiness remain separate integration-owner files.

For standalone automation, `bash native/linux/ScreenShare/test-build.sh` runs formatting, lint, native tests, release build, and real-binary packaging checks without accessing a desktop.
When using `CARGO_TARGET_DIR`, set it to an absolute path so staging and verification are independent of the caller's working directory.
The `.github/workflows/linux-wayland-helper.yml` job exercises this on the Ubuntu 22.04 x64 release baseline and uploads a build-only helper artifact.
Neither the automated job nor the package verifier establishes native desktop QA.

## Interface and lifetime

Run `--check` to test the session environment, GStreamer factories, and portal monitor/cursor support without requesting a session or capture.
This probe never establishes user consent and is not proof that a session will succeed.
Run `--version` or `--help` without any graphical session.
Unknown arguments fail with exit code 64.

With no arguments or `--read-only`, the helper requests one monitor and no input devices using a fresh combined RemoteDesktop/ScreenCast session.
Only `--allow-input` requests pointer/keyboard consent, and startup fails if both devices are not granted.
The input handlers also enforce the caller's read-only restriction independently of the portal's returned device mask.
No restore token is used or saved.
The returned device mask is authoritative; omitted devices are never injected.
The selected monitor is the only source connected through the portal-owned PipeWire file descriptor.
The helper waits for a real BGRx frame before binding `127.0.0.1:0` and printing `PORT=<port>` followed by a newline.
It serves one RFB 3.8 viewer and exits on disconnect; reconnecting requires another consent session.
It never binds a public interface.
RFB security type None matches the existing local relay contract, so loopback access is not an isolation boundary against other processes on the host.
Do not expose this listener through arbitrary tunnels or advertise this as a multi-tenant desktop server.

Consent is bounded to 100 seconds, preflight to 5 seconds, first frame to 15 seconds, and viewer attachment to 30 seconds.
The Elixir startup deadline is 125 seconds.
Owner stdin EOF and SIGTERM are watched even during consent.
Session closure, capture EOS/error, malformed RFB messages, or input failures end sharing.
Normal teardown releases held keys/buttons and closes the portal session; interrupted setup releases the process's D-Bus/PipeWire descriptors on exit.
No daemon, restore token, global GNOME setting, or permission bypass is installed.

## Limits and verification

Frames are capped at 16,777,216 pixels, 8192 pixels per dimension, and one pending frame; RFB encoding retains at most one additional frame.
Padding and unused pixel bytes are not sent to the viewer.
Raw encoding supports true-color 16-bit and 32-bit pixel formats with validated, non-overlapping masks.
Framebuffer requests and input coordinates must remain within the selected stream.
Pointer input scales from captured pixels to the portal's logical monitor size for HiDPI displays.
A missing logical size fails rather than guessing input coordinates.
Changing monitor resolution terminates the viewer with a reconnect-required error rather than injecting input into stale geometry.
Clipboard payloads are bounded and discarded because clipboard permission is not requested.
Audio, touch, multiple-monitor stitching, clipboard sharing, unattended login-screen control, and compositor-specific non-portal protocols are not implemented.

Permission-free tests cover frame bounds/padding, pixel negotiation, real TCP RFB exchanges, input coordinate conversion, argument handling, owner EOF, and Elixir helper process contracts.
Fixture pixels exist only in protocol tests; the executable has no fake capture mode.
No actual desktop capture or input injection was performed during this implementation.
GNOME and KDE consent, denial, revocation, HiDPI input, lock/unlock, monitor unplug, and viewer teardown remain explicit opt-in acceptance checks.

## Sources

- [XDG RemoteDesktop lifecycle, consent, input, and ScreenCast integration](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html)
- [XDG ScreenCast streams and PipeWire remote](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html)
- [PipeWire portal access control](https://docs.pipewire.org/page_portal.html)
- [ASHPD 0.11.1 RemoteDesktop implementation and examples](https://docs.rs/ashpd/0.11.1/src/ashpd/desktop/remote_desktop.rs.html)
- [ASHPD 0.11.1 ScreenCast implementation](https://docs.rs/ashpd/0.11.1/src/ashpd/desktop/screencast.rs.html)
- [RFB protocol, including the mandatory raw fallback](https://www.rfc-editor.org/rfc/rfc6143.html#section-7.5.2)

D-Bus Notify input is selected for portal compatibility; the official API recommends EIS for newer integrations but still documents Notify methods.
The helper never opens an EIS connection, because mixing EIS and Notify input in one session is prohibited by the portal contract.
