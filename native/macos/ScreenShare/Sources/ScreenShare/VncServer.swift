/// VncServer.swift — Minimal RFB 3.8 server over TCP localhost.
///
/// Speaks just enough of the RFB protocol for a standard VNC client (noVNC,
/// TigerVNC, built-in macOS Screen Sharing) to connect and see frames:
///
///   1. Version exchange (RFB 003.008)
///   2. Security negotiation — Security type 1 (None) only
///   3. Security result (OK)
///   4. ClientInit / ServerInit
///   5. Message loop:
///      - Receives FramebufferUpdateRequest → sends one raw-encoded update
///      - Receives SetPixelFormat / SetEncodings / KeyEvent / PointerEvent → ack/ignore
///      - Receives ClientCutText → ignore
///
/// Only one client at a time is served. A second connection attempt is
/// accepted then immediately closed (VNC clients retry automatically).
///
/// Frame source is swapped atomically via `setFrameSource(_:)` — the Capture
/// delegate calls this with live frames, while the stub mode uses a solid colour.

import Foundation
import Network

// MARK: - Frame Source

enum FrameSource {
    case stub
    case live(width: Int, height: Int, data: Data)
}

// MARK: - VncServer

final class VncServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    private var stopped = false

    // Atomic frame storage — updated by Capture, read by the send loop
    private let frameLock = NSLock()
    private var _frameSource: FrameSource = .stub
    private var pendingUpdateRequest = false

    // Default stub dimensions — overridden once a live frame arrives
    private var stubWidth  = 1920
    private var stubHeight = 1080

    init(port: UInt16) {
        self.port = port
    }

    // MARK: - Public

    func bind() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        // Restrict to loopback — never accept outside connections
        params.requiredInterfaceType = .loopback

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ScreenShare", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener
        fputs("[ScreenShare] bound 127.0.0.1:\(port)\n", stderr)

        // Announce port on stdout so the Elixir MacOS adapter can discover it
        // via the PORT= pattern (same contract as x11vnc.ex).
        print("PORT=\(port)")
        fflush(stdout)
    }

    func stop() {
        stopped = true
        connection?.cancel()
        listener?.cancel()
    }

    func setFrameSource(_ source: FrameSource) {
        frameLock.lock()
        _frameSource = source
        frameLock.unlock()
    }

    // MARK: - Accept loop

    func acceptLoop() async {
        guard let listener = listener else { return }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }

            if self.connection != nil {
                // Already serving one client — reject
                conn.cancel()
                return
            }

            fputs("[ScreenShare] client_connected\n", stderr)
            self.connection = conn
            conn.start(queue: .global(qos: .userInteractive))

            Task { await self.serve(conn) }
        }

        listener.start(queue: .global(qos: .userInteractive))

        // Keep the task alive until stopped
        while !stopped {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Per-connection RFB handshake + message loop

    private func serve(_ conn: NWConnection) async {
        do {
            // 1. Send version
            try await send(conn, data: FrameEncoder.protocolVersion())

            // 2. Receive client version (12 bytes) — we accept any, reply with None
            _ = try await recv(conn, count: 12)

            // 3. Send security types (1 = None)
            try await send(conn, data: FrameEncoder.securityTypes())

            // 4. Receive client security type choice (1 byte)
            _ = try await recv(conn, count: 1)

            // 5. Send security result (OK)
            try await send(conn, data: FrameEncoder.securityResult())

            // 6. Receive ClientInit (1 byte — shared-flag, ignored)
            _ = try await recv(conn, count: 1)

            // 7. Determine initial dimensions
            let (initWidth, initHeight) = frameDimensions()

            // 8. Send ServerInit
            try await send(conn, data: FrameEncoder.serverInit(width: initWidth, height: initHeight))

            // 9. Message loop
            try await messageLoop(conn, width: initWidth, height: initHeight)

        } catch {
            fputs("[ScreenShare] client_disconnected (\(error))\n", stderr)
        }

        connection = nil
        fputs("[ScreenShare] client_disconnected\n", stderr)
    }

    private func messageLoop(_ conn: NWConnection, width: Int, height: Int) async throws {
        while !stopped {
            // Read message type (1 byte)
            let typeByte = try await recv(conn, count: 1)
            guard let msgType = typeByte.first else { break }

            switch msgType {
            case RFBClientMsg.framebufferUpdateRequest.rawValue:
                // 9 bytes: incremental(1) x(2) y(2) w(2) h(2)
                _ = try await recv(conn, count: 9)
                // Send one full-screen update
                let frameData = currentFrame(width: width, height: height)
                let update = FrameEncoder.framebufferUpdate(x: 0, y: 0, width: width, height: height, pixelData: frameData)
                try await send(conn, data: update)

            case RFBClientMsg.setPixelFormat.rawValue:
                _ = try await recv(conn, count: 19) // 3 padding + 16 format bytes

            case RFBClientMsg.setEncodings.rawValue:
                let header = try await recv(conn, count: 3) // 1 padding + 2 count
                let count = Int(header[1]) << 8 | Int(header[2])
                _ = try await recv(conn, count: count * 4) // each encoding is int32

            case RFBClientMsg.keyEvent.rawValue:
                _ = try await recv(conn, count: 7) // down(1) pad(2) key(4)

            case RFBClientMsg.pointerEvent.rawValue:
                _ = try await recv(conn, count: 5) // buttonMask(1) x(2) y(2)

            case RFBClientMsg.clientCutText.rawValue:
                let header = try await recv(conn, count: 7) // 3 padding + 4 length
                let length = Int(header[3]) << 24 | Int(header[4]) << 16 |
                             Int(header[5]) << 8  | Int(header[6])
                if length > 0 { _ = try await recv(conn, count: length) }

            default:
                // Unknown message — terminate connection
                fputs("[ScreenShare] unknown client message type=\(msgType)\n", stderr)
                return
            }
        }
    }

    // MARK: - Frame helpers

    private func frameDimensions() -> (Int, Int) {
        frameLock.lock()
        defer { frameLock.unlock() }
        switch _frameSource {
        case .stub:
            return (stubWidth, stubHeight)
        case .live(let w, let h, _):
            return (w, h)
        }
    }

    private func currentFrame(width: Int, height: Int) -> Data {
        frameLock.lock()
        let src = _frameSource
        frameLock.unlock()

        switch src {
        case .stub:
            return stubFrame(width: width, height: height)
        case .live(_, _, let data):
            return data
        }
    }

    /// Solid dark-blue stub frame — 32-bit BGRA layout (matches PixelFormat declared in ServerInit)
    private func stubFrame(width: Int, height: Int) -> Data {
        // 4 bytes per pixel (32-bit pixel format: B G R pad)
        let pixelCount = width * height
        var data = Data(repeating: 0, count: pixelCount * 4)
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            var i = 0
            while i < pixelCount * 4 {
                ptr[i]     = 0x18 // B — dark blue
                ptr[i + 1] = 0x18 // G
                ptr[i + 2] = 0x2E // R
                ptr[i + 3] = 0xFF // pad / alpha (ignored by RFB)
                i += 4
            }
        }
        return data
    }

    // MARK: - NWConnection async helpers

    private func send(_ conn: NWConnection, data: Data) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func recv(_ conn: NWConnection, count: Int) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, data.count >= count {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: NSError(
                        domain: "ScreenShare", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Connection closed while reading"]))
                }
            }
        }
    }
}
