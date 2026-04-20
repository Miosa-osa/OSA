# Native Platform Helpers — Desktop Streaming

OSA's OpenComputers desktop streaming works on all three platforms via a uniform
architecture: a small native binary per platform binds a minimal RFB (VNC) server
on `127.0.0.1:5900`. The existing `Desktop.Controller` GenServer connects to that
socket identically on Linux, macOS, and Windows.

## Architecture

```
Platform OS                OSA (Elixir)               miosa-compute
──────────────────────     ──────────────────────     ──────────────
x11vnc (Linux)         →   Desktop.Controller      →   DesktopRelay
ScreenShare (macOS)    →   (RFB TCP 127.0.0.1:5900) →   (WebSocket)
ScreenShare.exe (Win)  →                            →   → browser
```

The native helpers expose `stdin/stdout` through a BEAM `Port`; OSA monitors
the port for exit and cleans up the session automatically.

## Binary inventory

| Platform    | Source                              | Runtime path                    | Adapter module              |
|-------------|-------------------------------------|---------------------------------|-----------------------------|
| Linux       | system `x11vnc`                     | system PATH                     | `Desktop.X11vnc`            |
| macOS       | `native/macos/ScreenShare/`         | `priv/macos/ScreenShare`        | `Desktop.MacOS`             |
| Windows     | `native/windows/ScreenShare/`       | `priv/windows/ScreenShare.exe`  | `Desktop.Windows`           |

## macOS build

Prerequisites: macOS 13+, Xcode CLI tools.

```sh
cd native/macos/ScreenShare
swift build -c release          # produces .build/release/ScreenShare

# Copy into priv/ for local testing with OSA:
mkdir -p priv/macos
cp .build/release/ScreenShare priv/macos/ScreenShare
```

## Windows build

Prerequisites: Windows 10 1903+, .NET 8 SDK.

```powershell
cd native/windows/ScreenShare
dotnet publish -c Release -r win-x64 --self-contained true -o publish

# Copy into priv/ for local testing:
New-Item -ItemType Directory -Force -Path priv\windows
Copy-Item publish\ScreenShare.exe priv\windows\ScreenShare.exe
```

## Configuration

Override the binary path at runtime via environment variables (useful when
developing without a full release build):

```sh
# macOS
export OSA_MACOS_HELPER="/path/to/ScreenShare"

# Windows
$env:OSA_WINDOWS_HELPER = "C:\path\to\ScreenShare.exe"
```

Or compile-time via `config/config.exs`:

```elixir
config :optimal_system_agent,
  macos_helper_path:   "/path/to/ScreenShare",
  windows_helper_path: "C:\\path\\to\\ScreenShare.exe"
```

## Stub mode

Both helpers accept `--stub` to skip real capture and serve a solid dark-blue
1920x1080 frame. This makes the full pipeline testable without screen recording
permission or GPU access:

```sh
# macOS
./ScreenShare --stub

# Windows
.\ScreenShare.exe --stub
```

## RFB protocol implementation

Both helpers implement RFC 6143 at the minimum level needed by VNC clients and
by OSA's `Desktop.Controller`:

| Feature               | Status   |
|-----------------------|----------|
| RFB 3.8 handshake     | Supported |
| Security type 1 (None)| Supported (localhost-only; no auth needed) |
| ServerInit            | Supported (32-bit BGRA pixel format) |
| FramebufferUpdate     | Supported (raw encoding, encoding type 0) |
| SetPixelFormat        | Accepted, ignored (format is fixed) |
| SetEncodings          | Accepted, ignored (raw only) |
| KeyEvent / PointerEvent | Accepted, ignored (Phase 2: forward to OS) |
| Clipboard (ClientCutText) | Accepted, ignored |
| zlib / ZRLE / Tight   | Not implemented |
| H.264 pseudo-encoding | Not implemented (Phase 3) |

## TCC permission — macOS

ScreenCaptureKit requires Screen Recording consent. On first launch the OS
prompts the user. If denied, the helper logs `[ScreenShare] permission_denied`
and falls back to stub mode automatically.

Grant/revoke: System Settings → Privacy & Security → Screen Recording.

## DPI awareness — Windows

The `app.manifest` sets `PerMonitorV2` DPI awareness. This ensures Desktop
Duplication returns pixels at the actual display resolution (not DPI-scaled).

## Adding a Wayland helper (Linux Phase 3)

The current Linux path uses `x11vnc` which requires an X11 display. For
Wayland-only systems (GNOME/KDE without XWayland), a similar native helper
can be built using `wlr-export-dmabuf-unstable-v1` or `xdg-desktop-portal`
pipewire capture. The `Desktop.X11vnc` adapter would gain a `linux_wayland`
variant in `controller.ex`.

## Adding H.264 encoding (Phase 3)

Current raw encoding sends ~6 MB/frame at 1920x1080 (30fps ≈ 180 MB/s). Phase 3:

macOS:
- `VideoToolbox.VTCompressionSession` → H.264 bitstream
- Serve via RFB `H264` pseudo-encoding or over WebRTC (replacing VNC entirely)

Windows:
- `MF.MFVideoEncoder` (Media Foundation) or `Nvenc`/`AMF` for GPU encoding
- Same RFB H.264 or WebRTC path

## Testing

### Manual smoke test (any platform)

```sh
# Start helper in stub mode, then connect with TigerVNC:
./ScreenShare --stub --port 5900
vncviewer 127.0.0.1:5900
# Expected: dark-blue 1920x1080 frame
```

### Automated Elixir tests

```sh
# Platform-independent tests (binary-missing path):
mix test test/optimal_system_agent/open_computers/executor/direct/desktop/

# With real binary on macOS:
mix test --include macos_native

# With real binary on Windows:
mix test --include windows_native
```

### nc port check

```sh
# After starting helper:
nc -z 127.0.0.1 5900 && echo "port open" || echo "port closed"
```

## CI integration

Two new jobs in `.github/workflows/release.yml` build the helpers before the
OSA release job runs:

- `build-macos-helper` — runs on `macos-14` (arm64), uploads `ScreenShare` artifact
- `build-macos-helper-x86` — runs on `macos-13` (x86_64), uploads x86 artifact
- `build-windows-helper` — runs on `windows-latest`, uploads `ScreenShare.exe` artifact

Each OSA release build job downloads the appropriate artifact into `priv/` before
running `mix release`. The release step function `copy_native_helpers/1` in
`mix.exs` copies `priv/macos/ScreenShare` and `priv/windows/ScreenShare.exe` into
the final release tree so they ship inside the Burrito bundle.

## Phase 2 remaining work

See `native/macos/ScreenShare/README.md` and `native/windows/ScreenShare/README.md`
for itemized specialist checklists.

Summary:

**macOS (Swift specialist)**
- Verify `SCStream` frame delivery and CVPixelBuffer pixel format
- Test multi-display enumeration
- Add frame rate throttle / drop under CPU pressure

**Windows (C# specialist)**
- Implement `Capture.cs` Desktop Duplication loop (all `TODO:P2` markers)
- Handle `DXGI_ERROR_ACCESS_LOST` (lock screen, resolution change)
- Test on multi-GPU systems (discrete + integrated)

**Both (Phase 3)**
- H.264 encoding for ~10x bandwidth reduction
- Key/pointer event forwarding to OS (makes it a full remote desktop, not just view)
