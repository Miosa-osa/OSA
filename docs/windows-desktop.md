# Windows Desktop Streaming

OSA's `stream_native_desktop` job on Windows works through a thin native helper binary
(`osa-screen-capture-windows.exe`) that bridges the Windows Desktop Duplication API into
the same RFB-over-TCP contract that the Linux and macOS paths use.

## Architecture

```
OSA (BEAM)
  └─ Desktop GenServer
       ├─ Windows.spawn/0  →  osa-screen-capture-windows.exe (C++/C# binary)
       │                           └─ Desktop Duplication API  (screen capture)
       │                           └─ SendInput                (input injection)
       │                           └─ RFB server               (127.0.0.1:PORT)
       ├─ Relay.open/1     →  Mint WebSocket → control plane
       └─ Bridge.start/3   →  TCP ↔ WebSocket pump
```

On startup the helper prints `PORT=<n>` to stdout. `Windows.ex` reads that line (same
pattern as `x11vnc.ex` on Linux and `macos.ex` on Darwin) and hands the port number to
`Bridge`, which pumps RFB frames between the local TCP socket and the outbound WebSocket
relay.

## Why a helper binary, not a NIF?

The Desktop Duplication API is a COM-based DXGI interface. Calling it from Elixir would
require a Rustler NIF that either shells out to COM dispatch or uses the Windows crate's
COM bindings — significantly more surface area than a standalone process.  A dedicated
binary is:

- **Isolated**: a crash in the capture loop cannot take down the BEAM.
- **Auditable**: Windows security prompts (UAC, antivirus) target a named `.exe`, not a
  dynamically-loaded library injected into the VM process.
- **Replaceable**: the binary can be updated independently of the OSA release.

## Required Windows Permissions

### Screen Capture
The Desktop Duplication API requires the calling process to be running in a session with
a DXGI output.  The helper must run on the same Windows session as the desktop being
captured (session 1 for a console/RDP session).

### Input Injection
`SendInput` works in most desktop sessions.  Restrictions apply in two scenarios:

1. **Secure Desktop** (UAC prompts, Ctrl+Alt+Del, lock screen): input injection into
   the secure desktop requires the process to be running with elevated privileges and the
   application manifest must declare `uiAccess="true"`.  Without this, `SendInput` calls
   silently succeed but events are dropped on the secure desktop.

2. **RDP / Remote Sessions**: `SendInput` operates on the session's input queue; if the
   session is disconnected (no active console), injection may not function as expected.

### Application Manifest
For full input support the helper binary ships with a manifest entry:

```xml
<requestedExecutionLevel level="asInvoker" uiAccess="true"/>
```

`uiAccess="true"` requires the binary to be:
- Signed with a trusted certificate.
- Located in a protected directory (`%ProgramFiles%` or `%SystemRoot%`).

In development builds (unsigned, arbitrary path) input injection works on normal
application windows but not on the secure desktop.

## Helper Lookup Order

`Windows.spawn/0` searches for the binary in this order:

1. `%USERPROFILE%\\.osa\helpers\osa-screen-capture-windows.exe` — user-local install
2. `<release_priv>/helpers/osa-screen-capture-windows.exe` — bundled in release

The `%USERPROFILE%` environment variable is read at runtime via `System.get_env/1`.
On Linux and macOS (e.g. CI) it will be absent, so the user path is skipped and only
the priv path is checked — making the lookup safe on all platforms.

If neither path exists, OSA returns `{:error, {:missing_helper, message}}` which
surfaces to the user as a job failure with the hint:

```
Install via: osa opencomputers install-helper
```

## Ship Status

**The native helper binary has not yet been shipped.**

`priv/helpers/osa-screen-capture-windows.exe.placeholder` documents the intended path.
The `.placeholder` suffix means it will not be matched by `Windows.find_helper/0` (which
looks for the `.exe` name exactly), so the missing-helper error path is exercised cleanly
in development.

For a pre-release build of the native helper, contact MIOSA support.

## Future Work: `osa opencomputers install-helper`

The planned CLI command will:

1. Detect OS + CPU architecture (`windows/amd64` or `windows/arm64`).
2. Download the signed binary from the MIOSA release CDN.
3. Verify the SHA-256 checksum.
4. Install to `%USERPROFILE%\.osa\helpers\osa-screen-capture-windows.exe`.
5. Print a reminder about UAC manifest requirements for secure-desktop input.

## RFB Protocol Notes

The helper implements a minimal RFB 3.8 server (same contract as macOS):

- Framebuffer: BGRA 32bpp (Desktop Duplication API native format — no pixel conversion).
- Encodings: Raw + ZRLE (ZRLE preferred for bandwidth efficiency).
- Authentication: None (bound to 127.0.0.1 only — the relay layer handles auth).
- Input: PointerEvent + KeyEvent messages forwarded to `SendInput`.

The VNC password dialog is intentionally disabled — authentication is handled by the
WebSocket relay's HMAC token, not by the RFB handshake.
