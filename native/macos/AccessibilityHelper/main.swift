import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// osa-accessibility-darwin
//
// A deliberately small JSON-speaking bridge around AXUIElement.  OSA keeps the
// provider-facing contract in Elixir; this process only crosses the macOS API
// boundary.  Each invocation is bounded by OSA, so a wedged application cannot
// stall an agent turn forever.

struct Options {
    var command = "snapshot"
    var maxDepth = 12
    var maxElements = 800
    var interactiveOnly = false
    var pid: pid_t?
    var path: [Int] = []
    var role = ""
    var name = ""
    var identifier = ""
    var action = kAXPressAction as String
    var value: String?
    var x: Int?
    var y: Int?
    var targetX: Int?
    var targetY: Int?
    var button = "left"
    var event = "click"
    var clicks = 1
    var direction = "down"
    var amount = 3
}

func argument(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func parseOptions() -> Options {
    let args = Array(CommandLine.arguments.dropFirst())
    var options = Options()
    if let first = args.first, !first.hasPrefix("--") { options.command = first }
    if let raw = argument("--max-depth", in: args), let n = Int(raw) { options.maxDepth = max(1, min(n, 30)) }
    if let raw = argument("--max-elements", in: args), let n = Int(raw) { options.maxElements = max(1, min(n, 5_000)) }
    options.interactiveOnly = args.contains("--interactive-only")
    if let raw = argument("--pid", in: args), let n = Int32(raw) { options.pid = n }
    if let raw = argument("--path", in: args), !raw.isEmpty {
        options.path = raw.split(separator: ".").compactMap { Int($0) }
    }
    options.role = argument("--role", in: args) ?? ""
    options.name = argument("--name", in: args) ?? ""
    options.identifier = argument("--identifier", in: args) ?? ""
    options.action = argument("--action", in: args) ?? (kAXPressAction as String)
    options.value = argument("--value", in: args)
    options.x = argument("--x", in: args).flatMap(Int.init)
    options.y = argument("--y", in: args).flatMap(Int.init)
    options.targetX = argument("--target-x", in: args).flatMap(Int.init)
    options.targetY = argument("--target-y", in: args).flatMap(Int.init)
    options.button = argument("--button", in: args) ?? "left"
    options.event = argument("--event", in: args) ?? "click"
    options.clicks = max(1, min(argument("--clicks", in: args).flatMap(Int.init) ?? 1, 3))
    options.direction = argument("--direction", in: args) ?? "down"
    options.amount = max(1, min(argument("--amount", in: args).flatMap(Int.init) ?? 3, 100))
    return options
}

func json(_ object: Any, exitCode: Int32 = 0) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
    exit(exitCode)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    json(["error": message], exitCode: code)
}

func trusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
    guard let value = copyAttribute(element, attribute) else { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    guard let value = copyAttribute(element, attribute) else { return nil }
    return (value as? NSNumber)?.boolValue
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    return copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    guard let raw = copyAttribute(element, attribute),
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    guard AXValueGetType(value) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    guard let raw = copyAttribute(element, attribute),
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    guard AXValueGetType(value) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

func normalizedRole(_ raw: String) -> String {
    let role = raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
    return role.replacingOccurrences(of: " ", with: "").lowercased()
}

func displayName(_ element: AXUIElement) -> String {
    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
        let value = stringAttribute(element, attribute as CFString)
        if !value.isEmpty { return value }
    }
    let value = stringAttribute(element, kAXValueAttribute as CFString)
    return value.count <= 160 ? value : ""
}

func node(_ element: AXUIElement, pid: pid_t, path: [Int], depth: Int) -> [String: Any] {
    let rawRole = stringAttribute(element, kAXRoleAttribute as CFString)
    let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
    let position = pointAttribute(element, kAXPositionAttribute as CFString) ?? .zero
    let size = sizeAttribute(element, kAXSizeAttribute as CFString) ?? .zero
    let actionNames = actions(element)
    var result: [String: Any] = [
        "pid": Int(pid),
        "path": path,
        "depth": depth,
        "role": normalizedRole(rawRole),
        "ax_role": rawRole,
        "subrole": subrole,
        "name": displayName(element),
        "identifier": stringAttribute(element, kAXIdentifierAttribute as CFString),
        "x": Int(position.x.rounded()),
        "y": Int(position.y.rounded()),
        "width": Int(size.width.rounded()),
        "height": Int(size.height.rounded()),
        "actions": actionNames
    ]
    let value = stringAttribute(element, kAXValueAttribute as CFString)
    if !value.isEmpty && !subrole.lowercased().contains("secure") { result["value"] = String(value.prefix(500)) }
    if let enabled = boolAttribute(element, kAXEnabledAttribute as CFString) { result["enabled"] = enabled }
    if let focused = boolAttribute(element, kAXFocusedAttribute as CFString) { result["focused"] = focused }
    if let selected = boolAttribute(element, kAXSelectedAttribute as CFString) { result["selected"] = selected }
    return result
}

func frontmostPID() -> pid_t? {
    let system = AXUIElementCreateSystemWide()
    if let raw = copyAttribute(system, kAXFocusedApplicationAttribute as CFString),
       CFGetTypeID(raw) == AXUIElementGetTypeID() {
        let app = unsafeBitCast(raw, to: AXUIElement.self)
        var pid: pid_t = 0
        if AXUIElementGetPid(app, &pid) == .success { return pid }
    }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

func snapshot(_ options: Options) -> Never {
    guard trusted(prompt: false) else {
        fail("Accessibility permission is required. Enable OSA or your terminal in System Settings > Privacy & Security > Accessibility.", code: 2)
    }
    guard let pid = options.pid ?? frontmostPID() else { fail("Could not determine the focused application") }
    let app = AXUIElementCreateApplication(pid)
    var output: [[String: Any]] = []
    var visited = Set<CFHashCode>()

    func walk(_ element: AXUIElement, path: [Int], depth: Int) {
        guard depth <= options.maxDepth, output.count < options.maxElements else { return }
        let identity = CFHash(element)
        guard !visited.contains(identity) else { return }
        visited.insert(identity)

        let item = node(element, pid: pid, path: path, depth: depth)
        let isInteractive = !((item["actions"] as? [String]) ?? []).isEmpty ||
            ["button", "link", "textfield", "textarea", "checkbox", "radio", "menuitem", "tab", "slider", "combobox", "switch", "searchfield", "popupbutton"].contains(item["role"] as? String ?? "")
        if !options.interactiveOnly || isInteractive { output.append(item) }
        for (index, child) in children(element).enumerated() {
            walk(child, path: path + [index], depth: depth + 1)
            if output.count >= options.maxElements { break }
        }
    }

    walk(app, path: [], depth: 0)
    json(output)
}

func elementAtPath(app: AXUIElement, path: [Int]) -> AXUIElement? {
    var current = app
    for index in path {
        let list = children(current)
        guard index >= 0, index < list.count else { return nil }
        current = list[index]
    }
    return current
}

func candidateMatches(_ element: AXUIElement, options: Options) -> Bool {
    if !options.identifier.isEmpty && stringAttribute(element, kAXIdentifierAttribute as CFString) != options.identifier { return false }
    if !options.role.isEmpty && normalizedRole(stringAttribute(element, kAXRoleAttribute as CFString)) != options.role { return false }
    if !options.name.isEmpty && displayName(element) != options.name { return false }
    return true
}

func findMatching(app: AXUIElement, options: Options) -> AXUIElement? {
    if let direct = elementAtPath(app: app, path: options.path), candidateMatches(direct, options: options) { return direct }
    // A bare role is not an identity. If an unnamed control moved, refusing is
    // safer than pressing the first button in the application.
    if options.identifier.isEmpty && options.name.isEmpty { return nil }
    var queue: [(AXUIElement, Int)] = [(app, 0)]
    var cursor = 0
    var visited = Set<CFHashCode>()
    while cursor < queue.count && cursor < 5_000 {
        let (element, depth) = queue[cursor]
        cursor += 1
        let identity = CFHash(element)
        if visited.contains(identity) { continue }
        visited.insert(identity)
        if candidateMatches(element, options: options) { return element }
        if depth < 30 { queue.append(contentsOf: children(element).map { ($0, depth + 1) }) }
    }
    return nil
}

func perform(_ options: Options) -> Never {
    guard trusted(prompt: false) else { fail("Accessibility permission is required", code: 2) }
    guard let pid = options.pid else { fail("perform requires --pid") }
    let app = AXUIElementCreateApplication(pid)
    guard let element = findMatching(app: app, options: options) else {
        fail("The accessibility reference is stale or the element no longer exists", code: 3)
    }

    let error: AXError
    if options.action == "AXSetValue" {
        guard let value = options.value else { fail("AXSetValue requires --value") }
        error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
    } else {
        error = AXUIElementPerformAction(element, options.action as CFString)
    }
    guard error == .success else { fail("Accessibility action \(options.action) failed with AXError \(error.rawValue)", code: 4) }
    json(["ok": true, "action": options.action])
}

func mouseButton(_ name: String) -> CGMouseButton {
    switch name {
    case "right": return .right
    case "middle": return .center
    default: return .left
    }
}

func mouseTypes(_ button: CGMouseButton) -> (CGEventType, CGEventType, CGEventType) {
    switch button {
    case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
    case .center: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
    default: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
    }
}

func postMouse(_ type: CGEventType, point: CGPoint, button: CGMouseButton, clickState: Int64 = 1) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    event.post(tap: .cghidEventTap)
}

func pointer(_ options: Options) -> Never {
    guard trusted(prompt: false) else { fail("Accessibility permission is required", code: 2) }

    if options.event == "cursor" {
        let point = CGEvent(source: nil)?.location ?? .zero
        json(["x": Int(point.x.rounded()), "y": Int(point.y.rounded())])
    }

    if options.event == "scroll" {
        let signed = Int32(options.amount) * (options.direction == "up" || options.direction == "left" ? 1 : -1)
        let vertical: Int32 = options.direction == "left" || options.direction == "right" ? 0 : signed
        let horizontal: Int32 = options.direction == "left" || options.direction == "right" ? signed : 0
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
            fail("Could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
        json(["ok": true, "event": "scroll"])
    }

    guard let x = options.x, let y = options.y else { fail("pointer requires --x and --y") }
    let point = CGPoint(x: x, y: y)
    let button = mouseButton(options.button)
    let (down, up, dragged) = mouseTypes(button)

    switch options.event {
    case "move": postMouse(.mouseMoved, point: point, button: button)
    case "down": postMouse(down, point: point, button: button)
    case "up": postMouse(up, point: point, button: button)
    case "drag":
        guard let targetX = options.targetX, let targetY = options.targetY else { fail("drag requires target coordinates") }
        postMouse(down, point: point, button: button)
        usleep(30_000)
        postMouse(dragged, point: CGPoint(x: targetX, y: targetY), button: button)
        usleep(30_000)
        postMouse(up, point: CGPoint(x: targetX, y: targetY), button: button)
    default:
        for count in 1...options.clicks {
            postMouse(down, point: point, button: button, clickState: Int64(count))
            usleep(12_000)
            postMouse(up, point: point, button: button, clickState: Int64(count))
            if count < options.clicks { usleep(70_000) }
        }
    }
    json(["ok": true, "event": options.event])
}

let options = parseOptions()
switch options.command {
case "snapshot": snapshot(options)
case "perform": perform(options)
case "pointer": pointer(options)
case "permissions": json(["trusted": trusted(prompt: CommandLine.arguments.contains("--prompt"))])
default: fail("Unknown command: \(options.command)")
}
