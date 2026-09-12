static class Program
{
    static async Task<int> Main(string[] args)
    {
        if (args.SequenceEqual(new[] { "--help" }))
        {
            Console.WriteLine("osa-screen-capture-windows [--port 0] [--display 0] [--read-only | --allow-input]");
            Console.WriteLine("Read-only by default. Requires the owner's unlocked interactive Windows desktop.");
            return 0;
        }
        try
        {
            var config = Config.Parse(args);
            var capture = new Capture(config.DisplayIndex);
            var input = config.AllowInput ? DesktopInput.ForWindows(capture, config.DisplayIndex) : null;
            using var cts = new CancellationTokenSource();
            ConsoleCancelEventHandler cancel = (_, e) => { e.Cancel = true; cts.Cancel(); };
            Console.CancelKeyPress += cancel;
            try
            {
                using var server = new VncServer(config.Port, capture.ReadFrame, input);
                // Bind captures a real frame before publishing the endpoint.
                server.Bind();
                if (Console.IsInputRedirected)
                    _ = Task.Run(() => WatchOwner(cts)); // Port stdin EOF terminates helper.
                var guard = WatchDesktop(cts);
                try { await server.AcceptLoopAsync(cts.Token); }
                finally
                {
                    cts.Cancel();
                    await guard;
                }
            }
            finally { Console.CancelKeyPress -= cancel; }
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ScreenShare] startup_or_capture_failed {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    private static void WatchOwner(CancellationTokenSource stop)
    {
        try
        {
            using var stdin = Console.OpenStandardInput();
            var buffer = new byte[128];
            while (!stop.IsCancellationRequested && stdin.Read(buffer, 0, buffer.Length) != 0) { }
        }
        catch (IOException) { }
        finally { try { stop.Cancel(); } catch (ObjectDisposedException) { } }
    }

    private static async Task WatchDesktop(CancellationTokenSource stop)
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                await Task.Delay(500, stop.Token);
                DesktopSession.RequireInteractive();
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        catch (Exception)
        {
            Console.Error.WriteLine("[ScreenShare] desktop_unavailable; stopping");
            stop.Cancel();
        }
    }
}
