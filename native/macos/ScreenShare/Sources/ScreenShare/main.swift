/// ScreenShare — macOS native VNC helper for OSA OpenComputers desktop streaming.
///
/// Entrypoint: parses CLI args, starts ScreenCaptureKit capture, runs minimal
/// RFB (VNC) server on localhost, forwards frames to any connected VNC client.
///
/// Usage:
///   ScreenShare [--port 5900] [--display 0] [--stub]
///
/// Flags:
///   --port N    TCP port for the RFB server (default: 5900)
///   --display N Display index to capture (default: 0; stub mode ignores this)
///   --stub      Skip real capture — serve solid-colour frames only.
///               Always active when ScreenCaptureKit permission is denied.
///
/// The binary is meant to be spawned by the Elixir MacOS adapter via Port/spawn.
/// It writes structured log lines to stderr so OSA can parse them:
///
///   [ScreenShare] starting port=5900
///   [ScreenShare] permission_granted
///   [ScreenShare] permission_denied — falling back to stub
///   [ScreenShare] capture_started display=0 1920x1080
///   [ScreenShare] client_connected addr=127.0.0.1
///   [ScreenShare] client_disconnected
///   [ScreenShare] stopping

import Foundation
import ScreenCaptureKit

// ---------------------------------------------------------------------------
// Parse CLI arguments
// ---------------------------------------------------------------------------

struct Config {
    var port: UInt16 = 5900
    var displayIndex: Int = 0
    var stub: Bool = false
}

func parseArgs(_ args: [String]) -> Config {
    var cfg = Config()
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--port":
            i += 1
            if i < args.count, let v = UInt16(args[i]) { cfg.port = v }
        case "--display":
            i += 1
            if i < args.count, let v = Int(args[i]) { cfg.displayIndex = v }
        case "--stub":
            cfg.stub = true
        default:
            break
        }
        i += 1
    }
    return cfg
}

let config = parseArgs(CommandLine.arguments)

fputs("[ScreenShare] starting port=\(config.port)\n", stderr)

// ---------------------------------------------------------------------------
// Signal handling — clean shutdown on SIGTERM / SIGINT
// ---------------------------------------------------------------------------

let stopSema = DispatchSemaphore(value: 0)

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSrc.setEventHandler { fputs("[ScreenShare] stopping\n", stderr); stopSema.signal() }
sigtermSrc.resume()

let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler { fputs("[ScreenShare] stopping\n", stderr); stopSema.signal() }
sigintSrc.resume()

// ---------------------------------------------------------------------------
// Permission check + capture start
// ---------------------------------------------------------------------------

var captureSource: SCStream? = nil

func startCapture(cfg: Config, server: VncServer) {
    if cfg.stub {
        fputs("[ScreenShare] stub mode — serving solid-colour framebuffer\n", stderr)
        server.setFrameSource(.stub)
        return
    }

    // ScreenCaptureKit availability guard (macOS 12.3+, but we target 13+)
    Task {
        do {
            let content = try await SCShareableContent.current
            let displays = content.displays

            guard !displays.isEmpty else {
                fputs("[ScreenShare] no displays found — falling back to stub\n", stderr)
                server.setFrameSource(.stub)
                return
            }

            let displayIdx = min(cfg.displayIndex, displays.count - 1)
            let display = displays[displayIdx]

            fputs("[ScreenShare] permission_granted\n", stderr)
            fputs("[ScreenShare] capture_started display=\(displayIdx) \(display.width)x\(display.height)\n", stderr)

            let captureConfig = SCStreamConfiguration()
            captureConfig.width = display.width
            captureConfig.height = display.height
            captureConfig.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 fps
            captureConfig.pixelFormat = kCVPixelFormatType_32BGRA
            captureConfig.showsCursor = true

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let capture = Capture(server: server)
            let stream = SCStream(filter: filter, configuration: captureConfig, delegate: capture)

            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()

            captureSource = stream
        } catch let err as NSError where err.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            // Error code -3801 = permission denied
            fputs("[ScreenShare] permission_denied — falling back to stub\n", stderr)
            server.setFrameSource(.stub)
        } catch {
            fputs("[ScreenShare] capture_error \(error) — falling back to stub\n", stderr)
            server.setFrameSource(.stub)
        }
    }
}

// ---------------------------------------------------------------------------
// Main — start VNC server and capture
// ---------------------------------------------------------------------------

let server = VncServer(port: config.port)

do {
    try server.bind()
} catch {
    fputs("[ScreenShare] fatal: cannot bind port \(config.port): \(error)\n", stderr)
    exit(1)
}

startCapture(cfg: config, server: server)

// Accept clients in background
Task.detached {
    await server.acceptLoop()
}

// Block main thread until signal
stopSema.wait()

// Graceful cleanup
if let s = captureSource {
    Task { try? await s.stopCapture() }
}
server.stop()
