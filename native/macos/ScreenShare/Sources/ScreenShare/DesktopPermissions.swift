import ApplicationServices
import CoreGraphics

enum DesktopPermissionError: Error {
    case screenRecordingDenied
}

/// Read-only permission inspection. Never requests or grants TCC permissions.
struct DesktopPermissions {
    var screen: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var input: () -> Bool = { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

    func requireCapture() throws {
        guard screen() else { throw DesktopPermissionError.screenRecordingDenied }
    }

    func inputAllowed(requested: Bool) -> Bool { requested && input() }
}
