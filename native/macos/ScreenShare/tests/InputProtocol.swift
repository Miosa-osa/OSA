import CoreGraphics
import Foundation

/// Real RFB transport, synthetic framebuffer, recording-only input sink.
@main
struct InputProtocol {
    static func main() throws {
        let lifetime = Lifetime(memoryMB: 128, idleSeconds: 10)
        let input = DesktopInput(allowInput: CommandLine.arguments.contains("--allow-input"),
                                 permitted: { true }, emit: { event in
            print("EVENT=\(event.type.rawValue)")
            fflush(stdout)
        })
        input.configure(bounds: CGRect(x: 0, y: 0, width: 8, height: 8), width: 8, height: 8)
        lifetime.beforeExit = { input.releaseAll() }
        lifetime.start()
        let server = VncServer(port: 0, activity: { lifetime.activity() }, input: input)
        server.setFrameSource(.live(width: 8, height: 8, data: Data(repeating: 0x5a, count: 256)))
        try server.bind()
        Task { await server.acceptLoop() }
        RunLoop.main.run()
    }
}
