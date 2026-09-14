# Windows native desktop helper

## Implemented contract

The helper at `native/windows/ScreenShare` captures one real Windows display and serves RFB 3.8 on IPv4 loopback.
It is a native-desktop path, not a sandbox, virtual desktop, or VM runtime.
The executable is named `osa-screen-capture-windows.exe`.

The default port is zero, allowing Windows to select a free ephemeral port.
The helper captures and validates a real frame before printing exactly `PORT=<actual-port>` to stdout.
Diagnostic messages go to stderr.
Capture failure never substitutes synthetic pixels or advertises a stub desktop.

`--display 0` selects the primary monitor.
Other monitors follow in desktop-coordinate order.
Coordinates are native pixels, including displays positioned left of the primary monitor.
A topology or resolution change closes the session; start a new helper to obtain fresh RFB geometry.

## Capture implementation and tradeoff

The implementation uses Windows GDI `BitBlt` with `CAPTUREBLT` into a top-down 32-bit `CreateDIBSection`, followed by `GdiFlush` and a bounded copy.
The current cursor is composited into the captured image.
Every capture acquires and releases its GDI handles on the same thread.
There is no background frame queue.

This compatibility backend deliberately replaces the unimplemented DXGI skeleton.
It avoids adapter-specific DXGI device/duplication management and external Vortice packages.
It is CPU-based and Raw RFB uses more bandwidth than a GPU capture plus compressed video path.
Protected content can remain black under Windows capture restrictions.
This implementation does not bypass protected content and does not claim gaming, HDR, or video-conferencing performance.

Capture is request-driven and capped at 10 frames per second.
Each display is limited to 16 megapixels, with at most 64 MiB in a managed BGRA framebuffer plus the GDI surface.
Encoding uses one row buffer rather than allocating a second encoded full frame.
Large combined desktops and 8K monitors exceeding that cap are rejected explicitly.

## Permissions and security

Run OSA and the helper in the owner's active, unlocked interactive Windows session.
Session 0, Windows services, disconnected sessions, non-interactive window stations, alternate desktops, and secure desktops are refused.
The helper checks the active session and desktop before and after capture, before input, and every 500 ms while running.
It never calls `SwitchDesktop`, `SetThreadDesktop`, changes desktop ACLs, or requests elevation.

The manifest remains `asInvoker` with `uiAccess="false"`.
There is no UAC, lock-screen, Ctrl+Alt+Del, or elevated-application bypass.
Windows UIPI can refuse input into applications with higher integrity; input failure closes the RFB connection.
The helper reports a generic failure without logging keys, screen contents, or clipboard contents.

The default is **read-only**.
`--allow-input` enables keyboard and mouse input for that helper instance.
`--read-only` can be provided explicitly.
Conflicting or unknown options are rejected, including the former `--stub` option.
A client cannot enable input through an RFB message.

The OSA adapter must pass `--allow-input` only after validating the owner's corresponding desktop-control permission.
An adapter that invokes the binary without arguments gets view-only access.
The Windows native helper does not validate MIOSA capability grants itself; that remains the controller/relay responsibility.
Desktop availability must never be interpreted as permission to dispatch arbitrary workloads or read files.

RFB uses security type None for compatibility with the existing local relay.
Binding to `127.0.0.1` prevents direct remote access, but is **not authentication against other local processes/users**.
Use only with a trusted local-user environment and an authorized outbound relay; do not expose or port-forward this listener.
A session-token or local-process-authenticated transport would require a coordinated controller contract change.

## Input behavior

RFB keysyms are translated to Windows virtual keys for modifiers, navigation, function keys, and numeric keypad keys.
Printable text uses Unicode `SendInput`, including surrogate pairs.
Letters, digits and space use virtual keys while Ctrl, Alt, or Windows modifiers are held, preserving common shortcuts.
Locale-specific punctuation shortcuts and IME composition still require native keyboard-layout QA; this implementation does not guess US OEM keys.

Pointer input supports motion, left/middle/right buttons, and vertical/horizontal wheel pulses.
Absolute coordinates are normalized over the Windows virtual desktop, including negative monitor origins.
Out-of-display coordinates are rejected.
At most 128 distinct keys can remain held by a connection.

Normal disconnect, protocol error, timeout, parent stdin EOF, and orderly cancellation attempt to release every key and button pressed by that connection.
Cleanup continues if one release fails.
An OS-denied input release is logged, not bypassed.
Abrupt process termination such as `taskkill /F`, a crash, or a desktop becoming protected can prevent Windows from accepting cleanup.
The controller should close the bridge and owner stdin before resorting to forced termination.
Do not claim forced-kill cleanup is guaranteed.

## RFB bounds

Only RFB 3.8 is accepted.
Raw encoding is supported with negotiated 8-, 16-, and 32-bit true-colour formats, both byte orders.
Palette formats, overlapping masks, and malformed geometry are rejected.
Framebuffer updates honor the requested rectangle; an empty rectangle gets an empty update.
Clipboard payloads are consumed but never applied.

A single client is served at a time.
Additional clients are closed without interrupting the active stream.
Encoding lists are limited to 256 entries and clipboard payloads to 64 KiB before allocation.
Handshake timeout is 10 seconds, incomplete reads/writes have a 5-second deadline, each complete message has a 10-second budget, and idle clients time out after 120 seconds.
Frame capture errors and resizing close the connection instead of emitting stale frames.

## Build and packaging

Install a .NET 8 SDK.
Build from any supported SDK host; native Windows is still required for capture/input QA.

```sh
dotnet run --project native/windows/ScreenShare/tests/ProtocolTests.csproj
dotnet publish native/windows/ScreenShare/ScreenShare.csproj -c Release -r win-x64 --self-contained true -o artifacts/windows-x64
dotnet publish native/windows/ScreenShare/ScreenShare.csproj -c Release -r win-arm64 --self-contained true -o artifacts/windows-arm64
```

Both output directories contain an architecture-specific `osa-screen-capture-windows.exe`.
Do not overwrite a running helper when installing an update.
Package the matching executable at `priv/helpers/osa-screen-capture-windows.exe` in the corresponding release.
Sign and checksum the final release artifact through the release owner's normal process.
The Windows release lane now builds the helper and rejects a stale or missing helper in the assembled OTP release.
It also packages the owner-scoped [Windows enrollment bundle](windows-onboarding.md).
No helper or service was deployed during this implementation.

The canonical Elixir lookup is the bundled path or a hash-pinned override through `OSA_DESKTOP_HELPER_OVERRIDE` and `OSA_DESKTOP_HELPER_SHA256`.
A user-writable `~/.osa/helpers` directory is not a trusted fallback.
An unsigned local build is not a claim of a shipped or signed Windows release.

## Validation and remaining native acceptance

The portable tests exercise the real TCP server and Windows INPUT structure generation with a synthetic frame provider/native-call recording sink.
They do not capture or inject input into the testing machine.
They cover endpoint discovery, readiness failure, handshake rejection, real provided frame bytes, pixel format conversion, geometry, message bounds, fragmentation, read-only operation, input cleanup, multi-client rejection, capture errors, and Windows ABI layouts.
The initial endpoint regression failed on the original helper because it announced `PORT=0`.
The original helper also accepted an invalid RFB version and spun after listener shutdown.

Windows x64 and ARM64 compilation/publishing are separate from native acceptance.
Before release, an explicitly authorized Windows tester must verify:

1. Fresh unsigned/signed packaged executable startup and the announced ephemeral port.
2. Actual captured pixels and cursor on primary and secondary monitors, including mixed DPI and negative origins.
3. View-only mode never typing or clicking; input-enabled mode controlling an ordinary test application.
4. Modifier combinations, Unicode, non-US layouts, keypad, wheel and button cleanup on disconnect.
5. Lock/unlock, UAC, RDP disconnect, display resize/unplug and higher-integrity applications failing closed.
6. Owner stdin EOF and graceful controller shutdown without orphan processes or stuck input.
7. The MIOSA authenticated browser relay end to end, including owner authorization and session revocation.
8. Resource/bandwidth measurements during a sustained session and 4K capture.

No native Windows display, `SendInput`, hardware performance, signed-package installation, or authenticated MIOSA browser acceptance was exercised in the cross-platform test run.

## Official references

- [Microsoft BitBlt](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-bitblt)
- [Microsoft CreateDIBSection and synchronization](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createdibsection)
- [Microsoft OpenInputDesktop](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openinputdesktop)
- [Microsoft SendInput and UIPI restrictions](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)
- [Microsoft KEYBDINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput)
- [Microsoft MOUSEINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-mouseinput)
- [Microsoft single-file deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview)
- [RFB specification, RFC 6143](https://www.rfc-editor.org/rfc/rfc6143.html)
