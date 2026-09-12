import CoreGraphics
import Foundation

@main
struct InputTests {
    static func main() {
        var events: [CGEvent] = []
        let input = DesktopInput(allowInput: false, permitted: { true }, emit: { events.append($0) })
        input.configure(bounds: CGRect(x: -100, y: 50, width: 200, height: 100), width: 400, height: 200)
        input.key(down: true, keysym: 0x61)
        input.pointer(mask: 1, x: 20, y: 20)
        precondition(events.isEmpty, "read-only sessions must not inject")
        let active = DesktopInput(allowInput: true, permitted: { true }, emit: { events.append($0) })
        active.configure(bounds: CGRect(x: -100, y: 50, width: 200, height: 100), width: 400, height: 200)
        active.key(down: true, keysym: 0x61)
        active.key(down: false, keysym: 0x61)
        precondition(events.map { $0.type } == [.keyDown, .keyUp], "authorized key must reach sink")
        events.removeAll()
        active.pointer(mask: 1, x: 200, y: 100)
        active.pointer(mask: 1, x: 220, y: 120)
        active.pointer(mask: 0, x: 220, y: 120)
        precondition(events.map { $0.type } == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        precondition(events[0].location == CGPoint(x: 0, y: 100))
        events.removeAll()
        active.key(down: true, keysym: 0xffe1)
        active.key(down: true, keysym: 0x61)
        active.pointer(mask: 1, x: 20, y: 20)
        active.releaseAll()
        precondition(events.filter { $0.type == .keyUp }.count == 1)
        precondition(events.filter { $0.type == .flagsChanged }.count == 2)
        precondition(events.last?.type == .leftMouseUp)
        let count = events.count
        active.releaseAll()
        precondition(events.count == count, "cleanup must be idempotent")
        var permission = true
        let revocable = DesktopInput(allowInput: true, permitted: { permission }, emit: { events.append($0) })
        revocable.key(down: true, keysym: 0x62)
        permission = false
        revocable.key(down: true, keysym: 0x63)
        precondition(events.last?.type == .keyUp, "permission revocation must release held keys")
        print("input tests passed (recording sink, no posting)")
    }
}
