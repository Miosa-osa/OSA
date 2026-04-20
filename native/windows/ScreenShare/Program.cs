/// Program.cs — ScreenShare Windows entrypoint.
///
/// Parses CLI args, starts Desktop Duplication capture (or falls back to stub),
/// and runs the minimal RFB VNC server on localhost.
///
/// Usage:
///   ScreenShare.exe [--port 5900] [--display 0] [--stub]
///
/// Log lines (stderr):
///   [ScreenShare] starting port=5900
///   [ScreenShare] capture_started display=0 2560x1440
///   [ScreenShare] capture_error <msg> — falling back to stub
///   [ScreenShare] stub mode — serving solid-colour framebuffer
///   [ScreenShare] client_connected
///   [ScreenShare] client_disconnected
///   [ScreenShare] stopping

using System;
using System.Threading;
using System.Threading.Tasks;

static class Program
{
    static async Task Main(string[] args)
    {
        var config = ParseArgs(args);
        Console.Error.WriteLine($"[ScreenShare] starting port={config.Port}");

        using var cts = new CancellationTokenSource();

        // Graceful SIGTERM / Ctrl-C handler
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            Console.Error.WriteLine("[ScreenShare] stopping");
            cts.Cancel();
        };
        AppDomain.CurrentDomain.ProcessExit += (_, _) =>
        {
            Console.Error.WriteLine("[ScreenShare] stopping");
            cts.Cancel();
        };

        // Start the VNC server first so it can bind the port
        var server = new VncServer(config.Port);
        server.Bind();

        // Start capture in background — updates server.FrameSource when live frames arrive
        Capture? capture = null;
        if (!config.Stub)
        {
            capture = new Capture(server, config.DisplayIndex);
            _ = Task.Run(() => capture.Start(cts.Token), cts.Token);
        }
        else
        {
            Console.Error.WriteLine("[ScreenShare] stub mode — serving solid-colour framebuffer");
        }

        // Block until cancellation
        try
        {
            await server.AcceptLoopAsync(cts.Token);
        }
        catch (OperationCanceledException) { }

        capture?.Stop();
    }

    static Config ParseArgs(string[] args)
    {
        var cfg = new Config();
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--port":
                    if (i + 1 < args.Length && int.TryParse(args[++i], out var p)) cfg.Port = p;
                    break;
                case "--display":
                    if (i + 1 < args.Length && int.TryParse(args[++i], out var d)) cfg.DisplayIndex = d;
                    break;
                case "--stub":
                    cfg.Stub = true;
                    break;
            }
        }
        return cfg;
    }
}

sealed class Config
{
    public int Port        { get; set; } = 5900;
    public int DisplayIndex { get; set; } = 0;
    public bool Stub       { get; set; } = false;
}
