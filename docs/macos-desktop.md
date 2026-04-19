# macOS Desktop Streaming

OSA's `stream_native_desktop` job on macOS works through a thin native helper binary
(`osa-screen-capture-darwin`) that bridges Apple's ScreenCaptureKit framework into the
same RFB-over-TCP contract that the Linux path uses.

## Architecture

```
OSA (BEAM)
  └─ Desktop GenServer
       ├─ MacOS.spawn/0  →  osa-screen-capture-darwin (Swift binary)
       │                         └─ ScreenCaptureKit  (screen capture)
       │                         └─ CGEventCreate*    (input injection)
       │                         └─ RFB server        (127.0.0.1:PORT)
       ├─ Relay.open/1   →  Mint WebSocket → control plane
       └─ Bridge.start/3 →  TCP ↔ WebSocket pump
```

On startup the helper prints `PORT=<n>` to stdout. `MacOS.ex` reads that line (same
pattern as `x11vnc.ex` on Linux) and hands the port number to `Bridge`, which pumps RFB
frames between the local TCP socket and the outbound WebSocket relay.

## Why a helper binary, not a NIF?

ScreenCaptureKit and the Accessibility/CGEvent APIs are Objective-C/Swift frameworks.
Wrapping them as a Rustler NIF would require bridging Swift ↔ Rust ↔ BEAM — roughly 3x
the surface area. A standalone Swift process is:

- Isolated: a crash in the capture loop cannot take down the BEAM.
- Auditable: Screen Recording + Accessibility permissions are requested by a named
  binary, not a dynamically loaded `.so`, so macOS privacy dialogs show the correct app.
- Replaceable: the binary can be updated independently of the OSA release.

## Required macOS Permissions

The helper needs two entitlements. On first launch macOS will prompt automatically.
To grant them manually:

**System Settings → Privacy & Security → Screen Recording**
Add `osa-screen-capture-darwin` (or the terminal running `osagent`).

**System Settings → Privacy & Security → Accessibility**
Add `osa-screen-capture-darwin`.

Without Screen Recording the helper exits immediately with status 1. Without
Accessibility, mouse/keyboard injection silently fails (capture still works).

## Helper Lookup Order

`MacOS.spawn/0` searches for the binary in this order:

1. `~/.osa/helpers/osa-screen-capture-darwin` — user-local install
2. `<release_priv>/helpers/osa-screen-capture-darwin` — bundled in release

If neither path exists, OSA returns a `{:error, {:missing_helper, message}}` which
surfaces to the user as a job failure with the hint:

```
Install via: osa opencomputers install-helper
```

## Ship Status

**The native Swift binary has not yet been shipped.**

`priv/helpers/osa-screen-capture-darwin.placeholder` is a shell script that exits 1
with an informative message. It is present so the Elixir lookup path can be exercised
in development without the real binary.

For a pre-release build of the native helper, contact MIOSA support.

## Future Work: `osa opencomputers install-helper`

The planned CLI command will:

1. Detect OS + CPU architecture (`darwin/arm64` or `darwin/amd64`).
2. Download the signed binary from the MIOSA release CDN.
3. Verify the SHA-256 checksum.
4. Install to `~/.osa/helpers/osa-screen-capture-darwin` and `chmod +x`.
5. Print a reminder to grant Screen Recording + Accessibility permissions.

## RFB Protocol Notes

The helper implements a minimal RFB 3.8 server:

- Framebuffer: BGRA 32bpp (ScreenCaptureKit native format — no pixel conversion).
- Encodings: Raw + ZRLE (ZRLE preferred for bandwidth efficiency).
- Authentication: None (bound to 127.0.0.1 only — the relay layer handles auth).
- Input: PointerEvent + KeyEvent messages forwarded to CGEventPost.

The VNC password dialog is intentionally disabled — authentication is handled by the
WebSocket relay's HMAC token, not by the RFB handshake.
