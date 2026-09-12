import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureSessionError: Error {
    case displayUnavailable, firstFrameTimeout, inputPermissionDenied
}

/// Owns the capture stream and delegate through startup and teardown.
final class CaptureSession {
    private var stream: SCStream?
    private var delegate: Capture?

    func start(displayIndex: Int, server: VncServer,
               permissions: DesktopPermissions = DesktopPermissions()) async throws {
        try permissions.requireCapture()
        let content = try await SCShareableContent.current
        guard content.displays.indices.contains(displayIndex) else {
            throw CaptureSessionError.displayUnavailable
        }
        let display = content.displays[displayIndex]
        let config = SCStreamConfiguration()
        let scale = min(1.0, min(4096.0 / Double(display.width), 3072.0 / Double(display.height)))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        server.setDimensions(width: config.width, height: config.height)
        server.configureInput(bounds: CGDisplayBounds(display.displayID), width: config.width, height: config.height)
        let capture = Capture(server: server)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config, delegate: capture)
        self.delegate = capture
        self.stream = stream
        try stream.addStreamOutput(capture, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "osa.capture.frames", qos: .userInteractive,
                                             autoreleaseFrequency: .workItem))
        try await stream.startCapture()
        // A running stream is not yet evidence of pixels. Do not bind until the
        // delegate has accepted an actual frame. No permission-error stub path.
        for _ in 0..<100 {
            if server.hasLiveFrame { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await stream.stopCapture()
        throw CaptureSessionError.firstFrameTimeout
    }
}
