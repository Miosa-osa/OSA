using System.Diagnostics;
using System.Net.Sockets;

// Strict RFB 3.8, Raw encoding. Single reader/writer with no queued frames.
sealed class RfbConnection(NetworkStream stream, Func<DesktopFrame> capture, IDesktopInput? input)
{
    private PixelFormat _format = PixelFormat.Default;
    private long _lastFrame;

    public async Task RunAsync(CancellationToken token)
    {
        using (var handshake = CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            handshake.CancelAfter(TimeSpan.FromSeconds(10));
            var ct = handshake.Token;
            await Write(FrameEncoder.ProtocolVersion(), ct);
            if (!(await Read(12, ct)).AsSpan().SequenceEqual(FrameEncoder.ProtocolVersion()))
                throw new InvalidDataException("Expected RFB 3.8");
            await Write(FrameEncoder.SecurityTypes(), ct);
            if ((await Read(1, ct))[0] != 1) throw new InvalidDataException("Unsupported security choice");
            await Write(FrameEncoder.SecurityResult(), ct);
            if ((await Read(1, ct))[0] > 1) throw new InvalidDataException("Invalid shared flag");
            var frame = capture();
            frame.Validate();
            await Write(FrameEncoder.ServerInit(frame.Width, frame.Height, "OSA Windows desktop"), ct);
            Width = frame.Width; Height = frame.Height;
        }
        while (!token.IsCancellationRequested)
        {
            var type = (await Read(1, token, 120))[0];
            // A message has one deadline, not a new budget for every attacker-supplied byte.
            using var message = CancellationTokenSource.CreateLinkedTokenSource(token);
            message.CancelAfter(TimeSpan.FromSeconds(10));
            var ct = message.Token;
            switch (type)
            {
                case 0:
                    _format = PixelFormat.Parse((await Read(19, ct)).AsSpan(3));
                    break;
                case 2:
                    var count = FrameEncoder.ReadU16(await Read(3, ct), 1);
                    if (count > 256) throw new InvalidDataException("Too many encodings");
                    await Read(count * 4, ct); // Raw is mandatory baseline in RFB.
                    break;
                case 3:
                    var request = await Read(9, ct);
                    if (request[0] > 1) throw new InvalidDataException("Invalid incremental flag");
                    await SendFrame(request, ct);
                    break;
                case 4:
                    var key = await Read(7, ct);
                    if (key[0] > 1) throw new InvalidDataException("Invalid key state");
                    input?.Key(key[0] == 1, FrameEncoder.ReadU32(key, 3));
                    break;
                case 5:
                    var pointer = await Read(5, ct);
                    var x = FrameEncoder.ReadU16(pointer, 1);
                    var y = FrameEncoder.ReadU16(pointer, 3);
                    if (x >= Width || y >= Height) throw new InvalidDataException("Pointer outside framebuffer");
                    input?.Pointer(pointer[0], x, y);
                    break;
                case 6:
                    var length = FrameEncoder.ReadU32(await Read(7, ct), 3);
                    if (length > 65536) throw new InvalidDataException("Clipboard payload exceeds limit");
                    await Read((int)length, ct); // Clipboard is deliberately disabled.
                    break;
                default: throw new InvalidDataException("Unsupported RFB message");
            }
        }
    }

    private int Width { get; set; }
    private int Height { get; set; }

    private async Task SendFrame(byte[] request, CancellationToken token)
    {
        int x = FrameEncoder.ReadU16(request, 1), y = FrameEncoder.ReadU16(request, 3);
        int w = FrameEncoder.ReadU16(request, 5), h = FrameEncoder.ReadU16(request, 7);
        if (x + w > Width || y + h > Height) throw new InvalidDataException("Rectangle outside framebuffer");
        if (w == 0 || h == 0) { await Write(new byte[4], token); return; }
        var delay = 100 - Stopwatch.GetElapsedTime(_lastFrame).TotalMilliseconds;
        if (delay > 0) await Task.Delay(TimeSpan.FromMilliseconds(delay), token);
        _lastFrame = Stopwatch.GetTimestamp();
        var frame = capture();
        frame.Validate();
        if (frame.Width != Width || frame.Height != Height)
            throw new InvalidOperationException("Display resized; reconnect required");
        await Write(FrameEncoder.UpdateHeader(x, y, w, h), token);
        // One row-sized encoding buffer, never a second full-size framebuffer.
        var row = new byte[checked(w * _format.BytesPerPixel)];
        for (int line = y; line < y + h; line++)
        {
            _format.Encode(frame.Pixels.AsSpan((line * Width + x) * 4, w * 4), row);
            await Write(row, token);
        }
    }

    private async Task<byte[]> Read(int count, CancellationToken token, int timeoutSeconds = 5)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        var data = new byte[count];
        await stream.ReadExactlyAsync(data, deadline.Token);
        return data;
    }

    private async Task Write(byte[] data, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        await stream.WriteAsync(data, deadline.Token);
    }
}
