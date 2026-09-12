import CoreGraphics
import Foundation

/// Serializes one viewer's input state. Event posting is an injected system seam.
final class DesktopInput {
    private let lock = NSRecursiveLock()
    private let allowInput: Bool
    private let permitted: () -> Bool
    private let emit: (CGEvent) -> Void
    private var bounds = CGRect.zero
    private var width = 0
    private var height = 0
    private var held: [UInt32: KeyMapping] = [:]
    private var buttons: UInt8 = 0
    private var point = CGPoint.zero
    private var revoked = false

    private var flags: CGEventFlags {
        held.values.reduce(CGEventFlags()) { $0.union($1.modifier) }
    }

    init(allowInput: Bool, permitted: @escaping () -> Bool, emit: @escaping (CGEvent) -> Void) {
        self.allowInput = allowInput
        self.permitted = permitted
        self.emit = emit
    }

    func configure(bounds: CGRect, width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        self.bounds = bounds
        self.width = width
        self.height = height
    }

    func key(down: Bool, keysym: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard authorized(), let mapping = held[keysym] ?? KeyMapping.resolve(keysym) else { return }
        guard !down || mapping.supportsShortcut || flags.intersection([.maskControl, .maskCommand]).isEmpty else { return }
        if down { held[keysym] = mapping }
        else if held.removeValue(forKey: keysym) == nil { return }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: mapping.code, keyDown: down) else { return }
        event.flags = flags
        if let text = mapping.text, flags.intersection([.maskControl, .maskCommand]).isEmpty {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        emit(event)
    }
    func pointer(mask: UInt8, x: Int, y: Int) {
        lock.lock(); defer { lock.unlock() }
        guard authorized(), width > 0, height > 0,
            x >= 0, x < width, y >= 0, y < height else { return }
        point = CGPoint(x: bounds.minX + Double(x) * bounds.width / Double(width),
                        y: bounds.minY + Double(y) * bounds.height / Double(height))
        let types: [(UInt8, CGMouseButton, CGEventType, CGEventType)] = [
            (1, .left, .leftMouseDown, .leftMouseUp),
            (2, .center, .otherMouseDown, .otherMouseUp),
            (4, .right, .rightMouseDown, .rightMouseUp)
        ]
        var transitioned = false
        for (bit, button, down, up) in types where (mask ^ buttons) & bit != 0 {
            mouse(mask & bit != 0 ? down : up, button: button)
            transitioned = true
        }
        let rising = mask & ~buttons
        let vertical: Int32 = (rising & 8 != 0 ? 1 : 0) - (rising & 16 != 0 ? 1 : 0)
        let horizontal: Int32 = (rising & 32 != 0 ? 1 : 0) - (rising & 64 != 0 ? 1 : 0)
        if vertical != 0 || horizontal != 0,
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                wheel1: vertical, wheel2: horizontal, wheel3: 0) {
            event.flags = flags
            emit(event)
        } else if !transitioned {
            if mask & 1 != 0 { mouse(.leftMouseDragged, button: .left) }
            else if mask & 4 != 0 { mouse(.rightMouseDragged, button: .right) }
            else if mask & 2 != 0 { mouse(.otherMouseDragged, button: .center) }
            else { mouse(.mouseMoved, button: .left) }
        }
        buttons = mask
    }

    private func mouse(_ type: CGEventType, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                 mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = flags
        emit(event)
    }

    private func authorized() -> Bool {
        guard allowInput && !revoked else { return false }
        guard permitted() else {
            releaseAll()
            revoked = true
            return false
        }
        return true
    }

    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        // Release ordinary keys before modifiers, only for keys owned by this viewer.
        let keys = held.keys.sorted { (held[$0]!.modifier.isEmpty ? 0 : 1) < (held[$1]!.modifier.isEmpty ? 0 : 1) }
        for key in keys {
            guard let mapping = held.removeValue(forKey: key),
                let event = CGEvent(keyboardEventSource: nil, virtualKey: mapping.code, keyDown: false) else { continue }
            event.flags = flags
            emit(event)
        }
        if buttons & 1 != 0 { mouse(.leftMouseUp, button: .left) }
        if buttons & 2 != 0 { mouse(.otherMouseUp, button: .center) }
        if buttons & 4 != 0 { mouse(.rightMouseUp, button: .right) }
        buttons = 0
    }
}
