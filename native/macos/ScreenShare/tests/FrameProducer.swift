import CoreMedia
import CoreVideo
// Permission-free stress fixture using the production conversion and RFB code.
import Foundation
import ScreenCaptureKit

@main
struct FrameProducer {
    static func main() throws {
        let lifetime = Lifetime(memoryMB: 512, idleSeconds: 60)
        lifetime.start()
        let server = VncServer(port: 0, activity: { lifetime.activity() })
        let capture = Capture(server: server)
        var pixel: CVPixelBuffer?
        precondition(
            CVPixelBufferCreate(
                nil, 1920, 1080, kCVPixelFormatType_32BGRA,
                nil, &pixel) == kCVReturnSuccess)
        let buffer = pixel!
        CVPixelBufferLockBaseAddress(buffer, [])
        // Distinguishable from stub pixels, so the test proves live conversion.
        memset(
            CVPixelBufferGetBaseAddress(buffer), 0x5A,
            CVPixelBufferGetBytesPerRow(buffer) * 1080)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        precondition(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil,
                imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil,
                imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr)
        let frames = DispatchSource.makeTimerSource(
            queue: DispatchQueue(
                label: "osa.capture.fixture", autoreleaseFrequency: .workItem))
        frames.schedule(deadline: .now(), repeating: .milliseconds(33))
        frames.setEventHandler { capture.consume(sample!) }
        frames.resume()
        try server.bind()
        Task { await server.acceptLoop() }
        withExtendedLifetime((frames, capture, lifetime)) { RunLoop.main.run() }
    }
}
