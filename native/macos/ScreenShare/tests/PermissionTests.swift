import Foundation

@main
struct PermissionTests {
    static func main() async throws {
        let denied = DesktopPermissions(screen: { false }, input: { true })
        do {
            try denied.requireCapture()
            fatalError("denied capture must fail, never select stub frames")
        } catch DesktopPermissionError.screenRecordingDenied { }
        let server = VncServer(port: 0, activity: {})
        do {
            try await CaptureSession().start(displayIndex: 0, server: server, permissions: denied)
            fatalError("capture session must not bind or capture after denial")
        } catch DesktopPermissionError.screenRecordingDenied { }
        precondition(!server.hasLiveFrame)

        let viewOnly = DesktopPermissions(screen: { true }, input: { false })
        try viewOnly.requireCapture()
        precondition(!viewOnly.inputAllowed(requested: false))
        precondition(!viewOnly.inputAllowed(requested: true))
        let authorized = DesktopPermissions(screen: { true }, input: { true })
        precondition(!authorized.inputAllowed(requested: false))
        precondition(authorized.inputAllowed(requested: true))
        print("permission tests passed (synthetic checks only)")
    }
}
