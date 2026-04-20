# ScreenShare — macOS native VNC helper

A minimal Swift binary that captures the macOS primary display using
ScreenCaptureKit and serves it as an RFB (VNC) stream on `127.0.0.1:5900`.

OSA's `Desktop.MacOS` Elixir adapter spawns this binary via `Port.open/2` and
the existing `Desktop.Controller` connects to port 5900 exactly as it does for
`x11vnc` on Linux.

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`) or Xcode 15+
- Screen Recording permission granted in System Preferences

## Build

SPM (`swift build`) requires full Xcode on macOS 14+ with CLI tools only.
Use the provided `build.sh` which invokes `swiftc` directly:

```sh
cd native/macos/ScreenShare
./build.sh              # release build → .build/release/ScreenShare
./build.sh debug        # debug build
ARCH=x86_64 ./build.sh  # cross-compile Intel on Apple Silicon
```

For distribution (inside OSA's Burrito bundle), CI copies the binary to
`priv/macos/ScreenShare`. Local development can point at the build output:

```sh
export OSA_MACOS_HELPER="$(pwd)/.build/release/ScreenShare"
```

Note: The binary was verified to compile and pass RFB handshake smoke tests
on macOS Sequoia (Darwin 25.4.0) with Xcode CLT Swift 6.3.

## Run manually

```sh
# Default: real capture, port 5900
.build/release/ScreenShare

# Custom port
.build/release/ScreenShare --port 5901

# Stub mode (dark-blue frame, no permissions required)
.build/release/ScreenShare --stub

# Second display
.build/release/ScreenShare --display 1
```

## macOS TCC / Screen Recording permission

The first run triggers the system Screen Recording consent dialog. If denied,
the binary falls back to a solid-colour stub frame automatically — OSA stays
functional (the VNC client connects and sees a blue screen).

To grant permission manually:
1. System Settings → Privacy & Security → Screen Recording
2. Enable "ScreenShare" (or the OSA app if launched from the bundle)

The permission is tied to the binary's code identity. If you rebuild the binary
the system will re-prompt on first use.

## RFB protocol support

The server implements RFC 6143 at the minimum required level:
- Version 3.8
- Security type 1 (None) — no authentication; localhost-only binding
- ServerInit with 32-bit pixel format (BGRA, padded)
- FramebufferUpdate with raw encoding (encoding type 0)
- Handles: SetPixelFormat, SetEncodings, KeyEvent, PointerEvent, ClientCutText

Does not implement: zlib/ZRLE/Tight/CopyRect encodings, clipboard, cursor pseudo-encoding.
These are not needed by OSA's `Desktop.Controller` which consumes raw RFB bytes
and forwards them over the control-plane socket.

## Architecture

```
SCStream (30 fps)
   ↓  CMSampleBuffer
Capture.swift
   ↓  BGRx bytes (32-bit)
VncServer.swift  frameSource = .live(...)
   ↓  RFB FramebufferUpdate
TCP 127.0.0.1:5900
   ↓
Desktop.Controller (Elixir)
   ↓  {:desktop_data, ...}
FrameRouter → miosa-compute DesktopRelay → browser
```

## Phase 2 specialist checklist

The skeleton is complete and testable. A Swift specialist should verify:

- [ ] `SCStream` frame delivery — confirm `didOutputSampleBuffer` fires at 30 fps
- [ ] Pixel format: SCStream outputs `kCVPixelFormatType_32BGRA`; verify `CVPixelBufferGetPixelFormatType` matches before conversion
- [ ] `CVPixelBufferGetBytesPerRowOfPlane` vs `CVPixelBufferGetBytesPerRow` — use the latter for non-planar formats
- [ ] Multi-display: `SCShareableContent.current.displays` returns displays in system order; add `--list-displays` flag to make index selection user-friendly
- [ ] Entitlements file: if packaging in an app bundle (not needed for CLI tool spawned by OSA), add `com.apple.security.screen-recording` to the entitlements plist
- [ ] Frame rate throttle: under heavy CPU, drop frames rather than backpressure the VNC client. Add a frame token bucket.
- [ ] H.264 encoding (Phase 3): replace raw encoding with `VideoToolbox` VTCompressionSession → RFB H.264 pseudo-encoding for 10x bandwidth reduction

## Testing

After build, verify the full pipeline with TigerVNC or the macOS built-in Screen Sharing:

```sh
# Terminal 1: start in stub mode (no permissions needed)
.build/release/ScreenShare --stub

# Terminal 2: connect with TigerVNC
vncviewer 127.0.0.1:5900
# Expected: solid dark-blue 1920x1080 frame
```

Automated: `mix test --include macos_native` (requires built binary at project root path).
