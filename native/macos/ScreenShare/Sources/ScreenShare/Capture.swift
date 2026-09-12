/// Capture.swift — ScreenCaptureKit stream delegate + output handler.
///
/// Receives `CMSampleBuffer` frames from SCStream and pushes encoded RGB bytes
/// to the VncServer's frame store. The VncServer reads from this store when a
/// VNC client requests a FramebufferUpdate.

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class Capture: NSObject, SCStreamDelegate, SCStreamOutput {
    private weak var server: VncServer?

    init(server: VncServer) {
        self.server = server
        super.init()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[ScreenShare] stream stopped: \(error)\n", stderr)
        server?.stop()
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        consume(sampleBuffer)
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        autoreleasepool {
            guard sampleBuffer.isValid,
                let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            let stride = CVPixelBufferGetBytesPerRow(imageBuffer)
            guard width > 0, width <= 4096, height > 0, height <= 3072,
                let base = CVPixelBufferGetBaseAddress(imageBuffer)
            else { return }
            // Preserve all four BGRA bytes: ServerInit advertises 32 bits/pixel.
            // Store only the newest frame; the send loop awaits each write.
            var pixels = Data(count: width * height * 4)
            pixels.withUnsafeMutableBytes { destination in
                for row in 0..<height {
                    memcpy(
                        destination.baseAddress!.advanced(by: row * width * 4),
                        base.advanced(by: row * stride), width * 4)
                }
            }
            server?.setFrameSource(.live(width: width, height: height, data: pixels))
        }
    }
}
