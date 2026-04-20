/// Capture.swift — ScreenCaptureKit stream delegate + output handler.
///
/// Receives `CMSampleBuffer` frames from SCStream and pushes encoded RGB bytes
/// to the VncServer's frame store. The VncServer reads from this store when a
/// VNC client requests a FramebufferUpdate.

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class Capture: NSObject, SCStreamDelegate, SCStreamOutput {
    private weak var server: VncServer?

    init(server: VncServer) {
        self.server = server
        super.init()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[ScreenShare] stream stopped: \(error)\n", stderr)
        server?.setFrameSource(.stub)
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let width  = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return }

        // SCStream delivers kCVPixelFormatType_32BGRA — convert to 24-bit BGR
        // that RFB raw encoding expects (RFB pixel format set in ServerInit).
        let totalBytes = height * width * 3
        var rgb = Data(count: totalBytes)

        rgb.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let src = baseAddress.assumingMemoryBound(to: UInt8.self)
            var dstOffset = 0
            for row in 0..<height {
                let rowBase = row * bytesPerRow
                for col in 0..<width {
                    let px = rowBase + col * 4
                    // BGRA → BGR (drop alpha, reorder to match RFB PixelFormat below)
                    dst[dstOffset]     = src[px]     // B
                    dst[dstOffset + 1] = src[px + 1] // G
                    dst[dstOffset + 2] = src[px + 2] // R
                    dstOffset += 3
                }
            }
        }

        server?.setFrameSource(.live(width: width, height: height, data: rgb))
    }
}
