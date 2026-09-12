/// ScreenShare — macOS native VNC helper for OSA OpenComputers desktop streaming.
///
/// Entrypoint: parses CLI args, starts ScreenCaptureKit capture, runs minimal
/// RFB (VNC) server on localhost, forwards frames to any connected VNC client.
///
/// Usage:
///   ScreenShare [--port 5900] [--display 0] [--stub]
///
/// Flags:
///   --port N    TCP port for the RFB server (default: ephemeral)
///   --display N Display index to capture (default: 0; stub mode ignores this)
///   --stub      Skip real capture — serve solid-colour frames only.
///               Explicit synthetic test mode only; never a permission fallback.
///
/// The binary is meant to be spawned by the Elixir MacOS adapter via Port/spawn.
/// It writes structured log lines to stderr so OSA can parse them:
///
///   [ScreenShare] starting port=5900
///   [ScreenShare] permission_granted
///   [ScreenShare] capture_or_startup_failed screenRecordingDenied
///   [ScreenShare] capture_started display=0 1920x1080
///   [ScreenShare] client_connected addr=127.0.0.1
///   [ScreenShare] client_disconnected
///   [ScreenShare] stopping

import Foundation
import ScreenCaptureKit

// ---------------------------------------------------------------------------
// Parse CLI arguments
// ---------------------------------------------------------------------------

let config: Config
do { config = try Config.parse(Array(CommandLine.arguments.dropFirst())) }
catch {
    fputs("[ScreenShare] invalid_arguments\n", stderr)
    exit(64)
}

let permissions = DesktopPermissions()
if config.check {
    do {
        try permissions.requireCapture()
        print("READY=macos_capture")
        print("INPUT=\(permissions.inputAllowed(requested: true) ? "authorized" : "read_only")")
        exit(0)
    } catch {
        fputs("[ScreenShare] permission_denied screen_recording\n", stderr)
        exit(77)
    }
}

fputs("[ScreenShare] starting port=\(config.port)\n", stderr)

// ---------------------------------------------------------------------------
// Signal handling — clean shutdown on SIGTERM / SIGINT
// ---------------------------------------------------------------------------

let lifetime = Lifetime(memoryMB: config.memoryMB, idleSeconds: config.idleSeconds)
lifetime.start()

// ---------------------------------------------------------------------------
// Permission check + capture start
// ---------------------------------------------------------------------------

let captureSession = CaptureSession()

func startCapture(cfg: Config, server: VncServer) async throws {
    if cfg.stub {
        fputs("[ScreenShare] stub mode — serving solid-colour framebuffer\n", stderr)
        server.setFrameSource(.stub)
        return
    }

    if cfg.allowInput && !permissions.inputAllowed(requested: true) {
        throw CaptureSessionError.inputPermissionDenied
    }
    try await captureSession.start(displayIndex: cfg.displayIndex, server: server)
}

// ---------------------------------------------------------------------------
// Main — start VNC server and capture
// ---------------------------------------------------------------------------

let input = DesktopInput(allowInput: config.allowInput && !config.stub,
                         permitted: { permissions.inputAllowed(requested: true) },
                         emit: { $0.post(tap: .cghidEventTap) })
let server = VncServer(port: config.port, activity: { lifetime.activity() }, input: input)
lifetime.beforeExit = { input.releaseAll() }

Task {
    do {
        try await startCapture(cfg: config, server: server)
        try server.bind()
    } catch {
        fputs("[ScreenShare] capture_or_startup_failed \(error)\n", stderr)
        server.stop()
        exit(1)
    }
    await server.acceptLoop()
    server.stop()
    exit(0)
}

// ScreenCaptureKit and dispatch signal delivery need a live main run loop.
// Blocking this thread on a semaphore stranded shutdown handlers indefinitely.
RunLoop.main.run()
