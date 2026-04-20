/// VncServer.cs — Minimal RFB 3.8 server over TCP localhost.
///
/// Mirrors the architecture of the macOS Swift VncServer.swift.
/// Serves one VNC client at a time; a second connection is accepted then closed.
///
/// Frame source:
///   Default: stub (solid dark-blue frame, 1920x1080, 32bpp)
///   Live:    updated by Capture.cs via SetFrame() when real capture is running

using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

/// Client message type constants (client → server, per RFC 6143)
static class RfbClientMsg
{
    public const byte SetPixelFormat           = 0;
    public const byte SetEncodings             = 2;
    public const byte FramebufferUpdateRequest = 3;
    public const byte KeyEvent                 = 4;
    public const byte PointerEvent             = 5;
    public const byte ClientCutText            = 6;
}

sealed class VncServer : IDisposable
{
    private readonly int   _port;
    private TcpListener?   _listener;
    private TcpClient?     _activeClient;
    private bool           _disposed;

    // Frame storage — swapped by Capture, read by the send loop
    private readonly object _frameLock = new();
    private byte[]  _frameData;
    private int     _frameWidth  = 1920;
    private int     _frameHeight = 1080;
    private bool    _hasLiveFrame;

    public VncServer(int port)
    {
        _port      = port;
        _frameData = BuildStubFrame(1920, 1080);
    }

    // -------------------------------------------------------------------------
    // Public
    // -------------------------------------------------------------------------

    public void Bind()
    {
        _listener = new TcpListener(IPAddress.Loopback, _port);
        _listener.Start();
        Console.Error.WriteLine($"[ScreenShare] bound 127.0.0.1:{_port}");
    }

    /// Called by Capture with each live frame (BGR24 bytes).
    public void SetFrame(int width, int height, byte[] bgr24Data)
    {
        lock (_frameLock)
        {
            _frameWidth    = width;
            _frameHeight   = height;
            _frameData     = bgr24Data;
            _hasLiveFrame  = true;
        }
    }

    public async Task AcceptLoopAsync(CancellationToken token)
    {
        if (_listener is null) throw new InvalidOperationException("Call Bind() first");

        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(token);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[ScreenShare] accept error: {ex.Message}");
                continue;
            }

            if (_activeClient is not null && _activeClient.Connected)
            {
                // Already serving one client — reject
                client.Close();
                continue;
            }

            _activeClient = client;
            Console.Error.WriteLine("[ScreenShare] client_connected");

            // Serve this client; errors are caught inside
            _ = Task.Run(() => ServeAsync(client, token), CancellationToken.None);
        }
    }

    public void Stop()
    {
        _listener?.Stop();
        _activeClient?.Close();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
    }

    // -------------------------------------------------------------------------
    // Per-connection RFB handshake + message loop
    // -------------------------------------------------------------------------

    private async Task ServeAsync(TcpClient client, CancellationToken token)
    {
        try
        {
            using var stream = client.GetStream();

            // 1. Send version
            await WriteAsync(stream, FrameEncoder.ProtocolVersion(), token);

            // 2. Receive client version (12 bytes)
            _ = await ReadExactAsync(stream, 12, token);

            // 3. Send security types (1 = None)
            await WriteAsync(stream, FrameEncoder.SecurityTypes(), token);

            // 4. Receive client security type choice (1 byte)
            _ = await ReadExactAsync(stream, 1, token);

            // 5. Send security result (OK)
            await WriteAsync(stream, FrameEncoder.SecurityResult(), token);

            // 6. Receive ClientInit (1 byte — shared flag, ignored)
            _ = await ReadExactAsync(stream, 1, token);

            // 7. Send ServerInit with current dimensions
            int w, h;
            lock (_frameLock) { w = _frameWidth; h = _frameHeight; }
            await WriteAsync(stream, FrameEncoder.ServerInit(w, h), token);

            // 8. Message loop
            await MessageLoopAsync(stream, w, h, token);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Console.Error.WriteLine($"[ScreenShare] client_disconnected ({ex.Message})");
        }
        finally
        {
            _activeClient = null;
            client.Close();
            Console.Error.WriteLine("[ScreenShare] client_disconnected");
        }
    }

    private async Task MessageLoopAsync(NetworkStream stream, int w, int h, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            var typeBuf = await ReadExactAsync(stream, 1, token);
            switch (typeBuf[0])
            {
                case RfbClientMsg.FramebufferUpdateRequest:
                    // incremental(1) x(2) y(2) w(2) h(2) = 9 bytes
                    _ = await ReadExactAsync(stream, 9, token);
                    var (fw, fh, pixels) = CurrentFrame(w, h);
                    var update = FrameEncoder.FramebufferUpdate(0, 0, fw, fh, pixels);
                    await WriteAsync(stream, update, token);
                    break;

                case RfbClientMsg.SetPixelFormat:
                    // 3 padding + 16 format bytes
                    _ = await ReadExactAsync(stream, 19, token);
                    break;

                case RfbClientMsg.SetEncodings:
                    var encHeader = await ReadExactAsync(stream, 3, token); // 1 pad + 2 count
                    int count = (encHeader[1] << 8) | encHeader[2];
                    if (count > 0) _ = await ReadExactAsync(stream, count * 4, token);
                    break;

                case RfbClientMsg.KeyEvent:
                    _ = await ReadExactAsync(stream, 7, token); // down(1) pad(2) key(4)
                    break;

                case RfbClientMsg.PointerEvent:
                    _ = await ReadExactAsync(stream, 5, token); // mask(1) x(2) y(2)
                    break;

                case RfbClientMsg.ClientCutText:
                    var cutHeader = await ReadExactAsync(stream, 7, token); // 3 pad + 4 len
                    var len = (int)FrameEncoder.ReadU32(cutHeader, 3);
                    if (len > 0) _ = await ReadExactAsync(stream, len, token);
                    break;

                default:
                    Console.Error.WriteLine($"[ScreenShare] unknown client message type={typeBuf[0]}");
                    return;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Frame helpers
    // -------------------------------------------------------------------------

    private (int width, int height, byte[] pixels) CurrentFrame(int defaultW, int defaultH)
    {
        lock (_frameLock)
        {
            if (_hasLiveFrame)
                return (_frameWidth, _frameHeight, _frameData);

            return (defaultW, defaultH, BuildStubFrame(defaultW, defaultH));
        }
    }

    /// Solid dark-blue frame — 32-bit BGRA layout matching the declared ServerPixelFormat.
    private static byte[] BuildStubFrame(int width, int height)
    {
        // 4 bytes per pixel: B G R pad
        var data = new byte[width * height * 4];
        for (int i = 0; i < data.Length; i += 4)
        {
            data[i]     = 0x18; // B — dark blue
            data[i + 1] = 0x18; // G
            data[i + 2] = 0x2E; // R
            data[i + 3] = 0xFF; // pad (alpha-ignored by RFB)
        }
        return data;
    }

    // -------------------------------------------------------------------------
    // Stream helpers
    // -------------------------------------------------------------------------

    private static async Task WriteAsync(NetworkStream s, byte[] data, CancellationToken token)
        => await s.WriteAsync(data, 0, data.Length, token);

    private static async Task<byte[]> ReadExactAsync(NetworkStream s, int count, CancellationToken token)
    {
        var buf    = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int read = await s.ReadAsync(buf, offset, count - offset, token);
            if (read == 0) throw new InvalidOperationException("Connection closed by client");
            offset += read;
        }
        return buf;
    }
}
