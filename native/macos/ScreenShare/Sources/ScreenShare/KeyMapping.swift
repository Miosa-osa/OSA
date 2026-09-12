import CoreGraphics
import Foundation

struct KeyMapping {
    let code: CGKeyCode
    let text: String?
    let modifier: CGEventFlags
    var supportsShortcut: Bool = true

    static func resolve(_ keysym: UInt32) -> KeyMapping? {
        let special: [UInt32: CGKeyCode] = [
            0xff08: 51, 0xff09: 48, 0xff0d: 36, 0xff1b: 53, 0xffff: 117,
            0xff50: 115, 0xff57: 119, 0xff55: 116, 0xff56: 121,
            0xff51: 123, 0xff52: 126, 0xff53: 124, 0xff54: 125,
            0xffbe: 122, 0xffbf: 120, 0xffc0: 99, 0xffc1: 118,
            0xffc2: 96, 0xffc3: 97, 0xffc4: 98, 0xffc5: 100,
            0xffc6: 101, 0xffc7: 109, 0xffc8: 103, 0xffc9: 111
        ]
        let modifiers: [UInt32: (CGKeyCode, CGEventFlags)] = [
            0xffe1: (56, .maskShift), 0xffe2: (60, .maskShift),
            0xffe3: (59, .maskControl), 0xffe4: (62, .maskControl),
            0xffe9: (58, .maskAlternate), 0xffea: (61, .maskAlternate),
            0xffe7: (55, .maskCommand), 0xffe8: (54, .maskCommand),
            0xffeb: (55, .maskCommand), 0xffec: (54, .maskCommand)
        ]
        if let (code, flag) = modifiers[keysym] {
            return KeyMapping(code: code, text: nil, modifier: flag)
        }
        if let code = special[keysym] { return KeyMapping(code: code, text: nil, modifier: []) }
        let scalarValue = keysym & 0xff00_0000 == 0x0100_0000 ? keysym & 0x00ff_ffff : keysym
        guard (0x20...0x7e).contains(scalarValue) || (0xa0...0x10ffff).contains(scalarValue),
            keysym <= 0xff || keysym & 0xff00_0000 == 0x0100_0000,
            let scalar = UnicodeScalar(scalarValue) else { return nil }
        // Unicode carries text independently of keyboard layout. ANSI virtual keys
        // preserve common Command/Control shortcuts; those are not text insertion.
        let ansi: [Character: CGKeyCode] = [
            "a":0, "s":1, "d":2, "f":3, "h":4, "g":5, "z":6, "x":7, "c":8, "v":9,
            "b":11, "q":12, "w":13, "e":14, "r":15, "y":16, "t":17,
            "1":18, "2":19, "3":20, "4":21, "6":22, "5":23, "=":24, "9":25,
            "7":26, "-":27, "8":28, "0":29, "]":30, "o":31, "u":32, "[":33,
            "i":34, "p":35, "l":37, "j":38, "'":39, "k":40, ";":41, "\\":42,
            ",":43, "/":44, "n":45, "m":46, ".":47, " ":49, "`":50
        ]
        let text = String(scalar)
        let code = ansi[text.lowercased().first!]
        return KeyMapping(code: code ?? 0, text: text, modifier: [], supportsShortcut: code != nil)
    }
}
