using System.Collections.Concurrent;
using System.Net.Sockets;
using System.Runtime.InteropServices;

static class Tests
{
    private static int _passed;
    static async Task Main()
    {
        await Test("ephemeral PORT is connectable", async () =>
        {
            await using var host = new Host();
            Check(host.Port > 0, "real ephemeral port");
            using var client = await host.Connect();
        });
        await Test("capture failure never announces readiness", () =>
        {
            using var server = new VncServer(0, () => throw new InvalidOperationException("capture unavailable"));
            var output = new StringWriter(); var original = Console.Out;
            Console.SetOut(output);
            try { Throws<InvalidOperationException>(() => server.Bind()); }
            finally { Console.SetOut(original); }
            Check(output.ToString() == "", "no false PORT");
            return Task.CompletedTask;
        });
        await Test("strict version negotiation", async () =>
        {
            await using var host = new Host();
            using var client = await host.Connect();
            await Read(client, 12);
            await Send(client, "NOT RFB 3.8!"u8.ToArray());
            await Closed(client);
        });
        await Test("rejects security choice other than None", async () =>
        {
            await using var host = new Host();
            using var client = await host.Connect();
            await Read(client, 12); await Send(client, FrameEncoder.ProtocolVersion());
            await Read(client, 2); await Send(client, new byte[] { 2 });
            await Closed(client);
        });
        await Test("sends actual BGRA pixels with advertised 32bpp", async () =>
        {
            await using var host = new Host();
            using var client = await host.Ready();
            await Send(client, Request(0, 0, 2, 2));
            Equal(await Read(client, 16), FrameEncoder.UpdateHeader(0, 0, 2, 2));
            Equal(await Read(client, 16), Pixels());
        });
        await Test("honours cropped big-endian RGB565 request", async () =>
        {
            await using var host = new Host();
            using var client = await host.Ready();
            await Send(client, Format(new byte[] { 16, 16, 1, 1, 0, 31, 0, 63, 0, 31, 11, 5, 0, 0, 0, 0 }));
            await Send(client, Request(0, 1, 2, 1));
            Equal(await Read(client, 16), FrameEncoder.UpdateHeader(0, 1, 2, 1));
            Equal(await Read(client, 4), new byte[] { 0xf8, 0, 0xff, 0xff });
        });
        await Test("8bpp true colour encoding", async () =>
        {
            await using var host = new Host();
            using var client = await host.Ready();
            await Send(client, Format(new byte[] { 8, 8, 0, 1, 0, 7, 0, 7, 0, 3, 5, 2, 0, 0, 0, 0 }));
            await Send(client, Request(0, 0, 2, 2)); await Read(client, 16);
            Equal(await Read(client, 4), new byte[] { 3, 28, 224, 255 });
        });
        await Test("rejects palette and overlapping pixel formats", async () =>
        {
            foreach (var format in new[] {
                new byte[] {32,24,0,0,0,255,0,255,0,255,16,8,0,0,0,0},
                new byte[] {32,24,0,1,0,255,0,255,0,255,8,8,0,0,0,0}})
            {
                await using var host = new Host(); using var client = await host.Ready();
                await Send(client, Format(format)); await Closed(client);
            }
        });
        await Test("zero rectangle is an empty update", async () =>
        {
            await using var host = new Host(); using var client = await host.Ready();
            await Send(client, Request(0, 0, 0, 0)); Equal(await Read(client, 4), new byte[4]);
        });
        await Test("out of bounds request fails closed", async () =>
        {
            await using var host = new Host(); using var client = await host.Ready();
            await Send(client, Request(1, 1, 65535, 65535)); await Closed(client);
        });
        await Test("bounds clipboard allocation before reading body", async () =>
        {
            await using var host = new Host(); using var client = await host.Ready();
            await Send(client, new byte[] { 6, 0, 0, 0, 255, 255, 255, 255 }); await Closed(client);
        });
        await Test("bounds encoding count before reading body", async () =>
        {
            await using var host = new Host(); using var client = await host.Ready();
            await Send(client, new byte[] { 2, 0, 1, 1 }); await Closed(client);
        });
        await Test("read-only consumes input without injection", async () =>
        {
            // A null native sink is the read-only public server interface.
            await using var host = new Host(); using var client = await host.Ready();
            await Send(client, Key(true, 0xffe3));
            await Send(client, new byte[] { 5, 1, 0, 1, 0, 1 });
            await Send(client, Request(0, 0, 1, 1)); await Read(client, 20);
            // This loopback test runs on non-Windows too: any native injection would fail.
        });
        await Test("RFB input reaches SendInput mapping and disconnect releases held state", async () =>
        {
            var sent = new ConcurrentQueue<Native.Input>();
            var input = new DesktopInput(new(0, 0, 2, 2), () => new(0, 0, 2, 2), sent.Enqueue);
            await using var host = new Host(input: input); using var client = await host.Ready();
            await Send(client, Key(true, 0xffe3)); // left control
            await Send(client, Key(true, 'c'));
            await Send(client, new byte[] { 5, 1, 0, 1, 0, 1 });
            await Send(client, Request(0, 0, 1, 1)); await Read(client, 20); // barrier
            client.Dispose();
            await Until(() => sent.Count >= 7);
            var events = sent.ToArray();
            Check(events[0].Data.Keyboard.Vk == 0xa2, "Ctrl_L mapping");
            Check(events[1].Data.Keyboard.Vk == 'C', "shortcut VK");
            Check(events[2].Data.Mouse.X == 65535 && events[2].Data.Mouse.Y == 65535, "absolute normalization");
            Check(events.Count(e => e.Type == 1 && (e.Data.Keyboard.Flags & 2) != 0) == 2, "both key ups");
            Check(events.Any(e => e.Type == 0 && e.Data.Mouse.Flags == 4), "left button up");
        });
        await Test("only one client accepted; existing stream survives rejection", async () =>
        {
            await using var host = new Host(); using var first = await host.Ready();
            using var second = await host.Connect(); await Closed(second);
            await Send(first, Request(0, 0, 1, 1)); await Read(first, 20);
        });
        await Test("capture failure disconnects instead of sending stale pixels", async () =>
        {
            int count = 0;
            await using var host = new Host(() => ++count <= 2 ? Frame() : throw new InvalidOperationException("capture failed"));
            using var client = await host.Ready();
            await Send(client, Request(0, 0, 1, 1)); await Closed(client);
        });
        await Test("display resize requires reconnect, no malformed old geometry", async () =>
        {
            int count = 0;
            await using var host = new Host(() => ++count <= 2 ? Frame() : new DesktopFrame(1, 1, new byte[4]));
            using var client = await host.Ready();
            await Send(client, Request(0, 0, 1, 1)); await Closed(client);
        });
        await Test("host cancellation releases input before loop completes", async () =>
        {
            var sent = new ConcurrentQueue<Native.Input>();
            var input = new DesktopInput(new(0, 0, 2, 2), () => new(0, 0, 2, 2), sent.Enqueue);
            await using var host = new Host(input: input); using var client = await host.Ready();
            await Send(client, Key(true, 0xffe9));
            await Send(client, Request(0, 0, 1, 1)); await Read(client, 20);
            await host.DisposeAsync();
            Check(sent.Any(e => e.Type == 1 && (e.Data.Keyboard.Flags & 2) != 0), "Alt released");
        });
        await Test("fragmented transport preserves message boundaries", async () =>
        {
            await using var host = new Host(); using var client = await host.Ready();
            foreach (var value in Request(0, 0, 1, 1)) await Send(client, new byte[] { value });
            Equal(await Read(client, 16), FrameEncoder.UpdateHeader(0, 0, 1, 1));
            Equal(await Read(client, 4), new byte[] { 255, 0, 0, 0 });
        });
        await Test("invalid frame lengths rejected", () =>
        {
            Throws<InvalidDataException>(() => new DesktopFrame(1, 1, new byte[3]).Validate());
            Throws<InvalidDataException>(() => new DesktopFrame(65535, 65535, Array.Empty<byte>()).Validate());
            return Task.CompletedTask;
        });
        await Test("CLI defaults read-only and rejects ambiguous permissions", () =>
        {
            Check(Config.Parse(Array.Empty<string>()) == new Config(0, 0, false), "safe defaults");
            Check(Config.Parse(new[] { "--allow-input" }).AllowInput, "explicit input");
            foreach (var args in new[] {new[]{"--stub"},new[]{"--port","65536"},new[]{"--display","-1"},
                new[]{"--port"},new[]{"--port","1","--port","2"},new[]{"--allow-input","--read-only"}})
                Throws<ArgumentException>(() => Config.Parse(args));
            return Task.CompletedTask;
        });
        await Test("Unicode, extended keys, F keys and keypad map correctly", () =>
        {
            var unicode = KeyMap.Map(0x0101f642, false);
            Check(unicode.Length == 2 && unicode.All(i => i.Data.Keyboard.Flags == 4), "surrogate INPUT pair");
            Check(KeyMap.Map(0xffe4, false)[0].Data.Keyboard.Flags == 1, "extended right Ctrl");
            Check(KeyMap.Map(0xffc9, false)[0].Data.Keyboard.Vk == 0x7b, "F12");
            Check(KeyMap.Map(0xffb9, false)[0].Data.Keyboard.Vk == 0x69, "keypad 9");
            Check(KeyMap.Map(0x01110000, false).Length == 0, "invalid Unicode");
            return Task.CompletedTask;
        });
        await Test("wheel pulses and negative-monitor coordinates", () =>
        {
            var sent = new List<Native.Input>();
            var input = new DesktopInput(new(-1920, 0, 1920, 1080), () => new(-1920, 0, 3840, 1080), sent.Add);
            input.Pointer(8, 0, 0); input.Pointer(8, 0, 0); input.Pointer(0, 0, 0); input.Pointer(8, 0, 0);
            Check(sent[0].Data.Mouse.X == 0, "left virtual desktop");
            Check(sent.Count(e => e.Data.Mouse.Flags == 0x800) == 2, "rising-edge wheel pulses");
            return Task.CompletedTask;
        });
        await Test("cleanup attempts every held input even if one native release fails", () =>
        {
            int attempts = 0; bool fail = false;
            var input = new DesktopInput(new(0, 0, 2, 2), () => new(0, 0, 2, 2), _ =>
                { if (fail) { attempts++; throw new InvalidOperationException(); } });
            input.Key(true, 0xffe3); input.Key(true, 0xffe9); input.Pointer(1, 0, 0);
            fail = true;
            Throws<InvalidOperationException>(input.ReleaseAll);
            Check(attempts == 3, "all releases attempted");
            return Task.CompletedTask;
        });
        await Test("partial messages time out and free the connection", async () =>
        {
            await using var host = new Host(); using var client = await host.Ready();
            await Send(client, new byte[] { 0, 0 }); // Incomplete SetPixelFormat.
            using var timeout = new CancellationTokenSource(7000);
            Check(await client.GetStream().ReadAsync(new byte[1], timeout.Token) == 0, "partial message stayed open");
        });
        await Test("held keys are bounded and all are released", () =>
        {
            var sent = new List<Native.Input>();
            var input = new DesktopInput(new(0, 0, 2, 2), () => new(0, 0, 2, 2), sent.Add);
            for (uint i = 0; i < 128; i++) input.Key(true, 0x01000400 + i);
            Throws<InvalidDataException>(() => input.Key(true, 0x01000500));
            input.ReleaseAll();
            Check(sent.Count == 256, "128 key downs and key ups");
            return Task.CompletedTask;
        });
        await Test("failed key-up is retained for disconnect cleanup", () =>
        {
            int attempts = 0;
            var input = new DesktopInput(new(0, 0, 2, 2), () => new(0, 0, 2, 2), e =>
            {
                if (e.Type == 1 && (e.Data.Keyboard.Flags & 2) != 0 && ++attempts == 1)
                    throw new InvalidOperationException();
            });
            input.Key(true, 0xffe3);
            Throws<InvalidOperationException>(() => input.Key(false, 0xffe3));
            input.ReleaseAll();
            Check(attempts == 2, "cleanup retried the failed release");
            return Task.CompletedTask;
        });
        await Test("Windows ABI layouts match 64-bit SDK", () =>
        {
            Check(Marshal.SizeOf<Native.Input>() == 40, "INPUT size");
            Check(Marshal.OffsetOf<Native.Input>(nameof(Native.Input.Data)).ToInt32() == 8, "union alignment");
            Check(Marshal.SizeOf<Native.KeyboardInput>() == 24, "KEYBDINPUT size");
            Check(Marshal.SizeOf<Native.BitmapInfo>() == 44, "BITMAPINFO size");
            return Task.CompletedTask;
        });
        Console.WriteLine($"PASS {_passed} tests (no native capture/input executed)");
    }

    static async Task Test(string name, Func<Task> test) { await test(); _passed++; Console.WriteLine($"PASS {name}"); }
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void Equal(byte[] actual, byte[] expected) => Check(actual.SequenceEqual(expected), "bytes differ");
    static void Throws<T>(Action action) where T : Exception
    { try { action(); } catch (T) { return; } throw new Exception($"Expected {typeof(T).Name}"); }
    static byte[] Pixels() => new byte[] { 255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 255, 255, 255, 0 };
    static DesktopFrame Frame() => new(2, 2, Pixels());
    static byte[] Request(ushort x, ushort y, ushort w, ushort h)
    { var b = new byte[10]; b[0] = 3; int i = 2; foreach (var n in new[] { x, y, w, h }) FrameEncoder.WriteU16(b, ref i, n); return b; }
    static byte[] Key(bool down, uint sym)
    { var b = new byte[8]; b[0] = 4; b[1] = (byte)(down ? 1 : 0); int i = 4; FrameEncoder.WriteU32(b, ref i, sym); return b; }
    static byte[] Format(byte[] format) { var b = new byte[20]; format.CopyTo(b, 4); return b; }
    static async Task Send(TcpClient client, byte[] bytes)
    { using var ct = new CancellationTokenSource(3000); await client.GetStream().WriteAsync(bytes, ct.Token); }
    static async Task<byte[]> Read(TcpClient client, int count)
    { using var ct = new CancellationTokenSource(3000); var b = new byte[count]; await client.GetStream().ReadExactlyAsync(b, ct.Token); return b; }
    static async Task Closed(TcpClient client)
    {
        using var ct = new CancellationTokenSource(3000);
        try { Check(await client.GetStream().ReadAsync(new byte[1], ct.Token) == 0, "connection remained open"); }
        catch (IOException) { } // TCP reset is also fail-closed.
    }
    static async Task Until(Func<bool> condition)
    { for (int i = 0; i < 100; i++) { if (condition()) return; await Task.Delay(20); } throw new Exception("condition timed out"); }

    sealed class Host : IAsyncDisposable
    {
        readonly VncServer _server;
        readonly CancellationTokenSource _stop = new();
        readonly Task _accept;
        bool _disposed;
        public int Port { get; }
        public Host(Func<DesktopFrame>? capture = null, IDesktopInput? input = null)
        {
            _server = new VncServer(0, capture ?? Frame, input);
            var output = new StringWriter(); var old = Console.Out;
            Console.SetOut(output);
            try { _server.Bind(); } finally { Console.SetOut(old); }
            var announcement = output.ToString().Trim();
            Check(announcement.StartsWith("PORT="), "missing announcement");
            Port = int.Parse(announcement[5..]);
            _accept = _server.AcceptLoopAsync(_stop.Token);
        }
        public async Task<TcpClient> Connect()
        { var client = new TcpClient(); await client.ConnectAsync("127.0.0.1", Port); return client; }
        public async Task<TcpClient> Ready()
        {
            var client = await Connect();
            Equal(await Read(client, 12), FrameEncoder.ProtocolVersion());
            await Send(client, FrameEncoder.ProtocolVersion());
            Equal(await Read(client, 2), new byte[] { 1, 1 });
            await Send(client, new byte[] { 1 }); Equal(await Read(client, 4), new byte[4]);
            await Send(client, new byte[] { 1 });
            var init = await Read(client, 24);
            Check(FrameEncoder.ReadU16(init, 0) == 2 && FrameEncoder.ReadU16(init, 2) == 2, "init geometry");
            Check(init[4] == 32 && init[5] == 24, "init pixel format");
            await Read(client, (int)FrameEncoder.ReadU32(init, 20));
            return client;
        }
        public async ValueTask DisposeAsync()
        {
            if (_disposed) return; _disposed = true;
            _stop.Cancel(); _server.Dispose();
            await _accept.WaitAsync(TimeSpan.FromSeconds(3));
            _stop.Dispose();
        }
    }
}
