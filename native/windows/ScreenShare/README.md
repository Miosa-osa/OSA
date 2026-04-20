# ScreenShare — Windows native VNC helper

A minimal C# .NET 8 executable that captures the Windows primary display using
the Desktop Duplication API (DXGI + Direct3D 11) and serves it as an RFB (VNC)
stream on `127.0.0.1:5900`.

OSA's `Desktop.Windows` Elixir adapter spawns this binary via `Port.open/2` and
the existing `Desktop.Controller` connects to port 5900 exactly as it does for
`x11vnc` on Linux.

## Phase 1 status

The RFB server, frame encoder, and Elixir integration are complete and testable.
The Desktop Duplication capture (in `Capture.cs`) is a **stub** — `Start()` throws
`NotImplementedException` which is caught and causes the server to fall back to a
solid-colour frame. See Phase 2 checklist below.

## Requirements

- Windows 10 1903+ or Windows 11 (Desktop Duplication requires DXGI 1.2)
- .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`) — only needed to build;
  the published binary is fully self-contained

## Build

```powershell
cd native/windows/ScreenShare
dotnet publish -c Release -r win-x64 --self-contained true -o publish
# Binary: publish/ScreenShare.exe (~70 MB self-contained)
```

For OSA's Burrito bundle, CI copies `publish/ScreenShare.exe` to
`priv/windows/ScreenShare.exe`. Local development:

```powershell
$env:OSA_WINDOWS_HELPER = "$(Get-Location)\publish\ScreenShare.exe"
```

## Run manually

```powershell
# Stub mode (safe, no DXGI required)
publish\ScreenShare.exe --stub

# Real capture (Phase 2 — currently falls back to stub automatically)
publish\ScreenShare.exe

# Custom port
publish\ScreenShare.exe --port 5901 --stub

# Second monitor
publish\ScreenShare.exe --display 1
```

## Permissions

Desktop Duplication does NOT require UAC elevation. It runs at standard user
level as long as OSA is launched from the same desktop session (not as a Windows
service or SYSTEM). The app.manifest sets `asInvoker` execution level.

## RFB protocol support

Same as the macOS helper — see its README for the supported RFB message set.

## Architecture

```
DXGI OutputDuplication (Phase 2)
   ↓  BGRA texture (staging)
Capture.cs  → ConvertBgraToBgr24()
   ↓  BGR24 bytes
VncServer.cs  server.SetFrame(...)
   ↓  RFB FramebufferUpdate
TCP 127.0.0.1:5900
   ↓
Desktop.Controller (Elixir)
   ↓  {:desktop_data, ...}
FrameRouter → miosa-compute DesktopRelay → browser
```

## Phase 2 specialist checklist

All `TODO:P2` markers in `Capture.cs` trace the implementation path:

- [ ] Add `using Vortice.DXGI; using Vortice.Direct3D11;` after NuGet restore
- [ ] `D3D11.D3D11CreateDevice` — create hardware device (fall back to WARP if no GPU)
- [ ] `IDXGIAdapter.EnumOutputs(_displayIndex)` — enumerate outputs for multi-monitor
- [ ] `IDXGIOutput1.DuplicateOutput(device)` — create `IDXGIOutputDuplication`
- [ ] `AcquireNextFrame(timeoutMs=33, ...)` loop — 30 fps cap
- [ ] Handle `DXGI_ERROR_ACCESS_LOST` — recreate duplication (happens on resolution change, lock screen)
- [ ] Handle `DXGI_ERROR_WAIT_TIMEOUT` — no new frame, skip (don't send stale update)
- [ ] Staging texture: `Texture2DDescription` with `Usage=Staging, CPUAccessFlags=Read`
- [ ] `context.CopyResource(staging, capturedTexture)` + `context.Map(staging, 0, MapMode.Read, 0)`
- [ ] `ConvertBgraToBgr24`: unsafe pointer walk — each BGRA 4-byte pixel → 3-byte BGR
- [ ] `ReleaseFrame()` after every `AcquireNextFrame` even on error
- [ ] Log `[ScreenShare] capture_started display=N WxH` on first successful frame
- [ ] DPI awareness: verify `PerMonitorV2` in `app.manifest` gives real pixel dimensions

## Testing

```powershell
# Build in stub mode and connect
.\publish\ScreenShare.exe --stub
# In another terminal:
# vncviewer 127.0.0.1:5900  (TigerVNC for Windows)
# Expected: solid dark-blue 1920x1080 frame
```

Automated: `mix test --include windows_native` (requires built binary at project root path).
