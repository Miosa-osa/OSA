/// FrameEncoder.swift — Builds RFB protocol byte sequences.
///
/// Covers only what the minimal VNC server needs:
///   - RFB 3.8 handshake bytes (version string, security types, ServerInit)
///   - FramebufferUpdate message with a single raw-encoded rectangle
///   - Security type 1 (None) — sufficient for localhost-only server

import Foundation

// RFB message type IDs (server → client)
enum RFBServerMsg: UInt8 {
    case framebufferUpdate = 0
    case setColourMapEntries = 1
    case bell = 2
    case serverCutText = 3
}

// RFB message type IDs (client → server)
enum RFBClientMsg: UInt8 {
    case setPixelFormat = 0
    case setEncodings = 2
    case framebufferUpdateRequest = 3
    case keyEvent = 4
    case pointerEvent = 5
    case clientCutText = 6
}

struct PixelFormat {
    // 24-bit BGR packed into 32 bits (1 pad byte) — matches SCStream BGRA output
    static let bitsPerPixel:  UInt8  = 32
    static let depth:         UInt8  = 24
    static let bigEndian:     UInt8  = 0  // little-endian
    static let trueColour:    UInt8  = 1
    static let redMax:        UInt16 = 255
    static let greenMax:      UInt16 = 255
    static let blueMax:       UInt16 = 255
    static let redShift:      UInt8  = 16 // bits to shift in a 32-bit BGRA word
    static let greenShift:    UInt8  = 8
    static let blueShift:     UInt8  = 0
}

enum FrameEncoder {

    // MARK: - Handshake

    /// RFB 003.008\n (12 bytes)
    static func protocolVersion() -> Data {
        return Data("RFB 003.008\n".utf8)
    }

    /// Security types: count=1, type=1 (None)
    static func securityTypes() -> Data {
        return Data([1, 1])
    }

    /// Security result: OK (4 bytes, big-endian uint32 = 0)
    static func securityResult() -> Data {
        return Data([0, 0, 0, 0])
    }

    // MARK: - ServerInit

    /// ServerInit message (24 bytes + name length prefix + name bytes)
    static func serverInit(width: Int, height: Int, name: String = "ScreenShare") -> Data {
        var msg = Data()

        // Framebuffer width/height (big-endian uint16)
        msg.append(contentsOf: bigEndian16(UInt16(width)))
        msg.append(contentsOf: bigEndian16(UInt16(height)))

        // ServerPixelFormat (16 bytes)
        msg.append(PixelFormat.bitsPerPixel)
        msg.append(PixelFormat.depth)
        msg.append(PixelFormat.bigEndian)
        msg.append(PixelFormat.trueColour)
        msg.append(contentsOf: bigEndian16(PixelFormat.redMax))
        msg.append(contentsOf: bigEndian16(PixelFormat.greenMax))
        msg.append(contentsOf: bigEndian16(PixelFormat.blueMax))
        msg.append(PixelFormat.redShift)
        msg.append(PixelFormat.greenShift)
        msg.append(PixelFormat.blueShift)
        msg.append(contentsOf: [0, 0, 0]) // 3 padding bytes

        // Name length + name
        let nameBytes = Data(name.utf8)
        msg.append(contentsOf: bigEndian32(UInt32(nameBytes.count)))
        msg.append(nameBytes)

        return msg
    }

    // MARK: - FramebufferUpdate

    /// Build a FramebufferUpdate with one raw-encoded rectangle.
    ///
    /// - Parameters:
    ///   - x, y: top-left of the rectangle (usually 0,0 for full screen)
    ///   - width, height: rectangle size in pixels
    ///   - pixelData: raw RGB bytes in RFB pixel format (bitsPerPixel / 8 bytes per pixel)
    static func framebufferUpdate(x: Int, y: Int, width: Int, height: Int, pixelData: Data) -> Data {
        var msg = Data()

        // Message type (1 byte) + padding (1 byte)
        msg.append(RFBServerMsg.framebufferUpdate.rawValue)
        msg.append(0) // padding

        // Number of rectangles (big-endian uint16)
        msg.append(contentsOf: bigEndian16(1))

        // Rectangle header: x, y, w, h (big-endian uint16 each)
        msg.append(contentsOf: bigEndian16(UInt16(x)))
        msg.append(contentsOf: bigEndian16(UInt16(y)))
        msg.append(contentsOf: bigEndian16(UInt16(width)))
        msg.append(contentsOf: bigEndian16(UInt16(height)))

        // Encoding type: 0 = Raw (big-endian int32)
        msg.append(contentsOf: [0, 0, 0, 0])

        // Pixel data
        msg.append(pixelData)

        return msg
    }

    // MARK: - Helpers

    static func bigEndian16(_ v: UInt16) -> [UInt8] {
        [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    static func bigEndian32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}
