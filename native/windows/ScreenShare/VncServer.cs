using System.Net;
using System.Net.Sockets;

sealed class VncServer : IDisposable
{
    private readonly TcpListener _listener;
    private readonly Func<DesktopFrame> _capture;
    private readonly IDesktopInput? _input;
    private readonly CancellationTokenSource _stop = new();
    private readonly object _gate = new();
    private TcpClient? _client;
    private Task _serving = Task.CompletedTask;
    private bool _bound;
    private bool _disposed;

    public VncServer(int port, Func<DesktopFrame> capture, IDesktopInput? input = null)
    {
        if (port is < 0 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        _capture = capture;
        _input = input; // null is read-only; protocol cannot enable input.
        _listener = new TcpListener(IPAddress.Loopback, port);
        _listener.Server.ExclusiveAddressUse = true;
    }

    public void Bind()
    {
        // Do not announce readiness unless real capture succeeded.
        _capture().Validate();
        _listener.Start(1);
        _bound = true;
        var port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        Console.Out.WriteLine($"PORT={port}");
        Console.Out.Flush();
    }

    public async Task AcceptLoopAsync(CancellationToken token)
    {
        if (!_bound) throw new InvalidOperationException("Call Bind first");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, _stop.Token);
        try
        {
            while (!linked.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(linked.Token);
                client.NoDelay = true;
                lock (_gate)
                {
                    if (_client != null) { client.Dispose(); continue; }
                    _client = client;
                    _serving = ServeAsync(client, linked.Token);
                }
            }
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested) { }
        catch (SocketException) when (linked.IsCancellationRequested) { }
        catch (ObjectDisposedException) when (linked.IsCancellationRequested) { }
        finally
        {
            _listener.Stop();
            lock (_gate) _client?.Dispose();
            await _serving;
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken token)
    {
        try
        {
            using var stream = client.GetStream();
            await new RfbConnection(stream, _capture, _input).RunAsync(token);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or SocketException or OperationCanceledException or ObjectDisposedException
            or InvalidOperationException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            // No pixels, keys, clipboard, or user data in logs.
            Console.Error.WriteLine($"[ScreenShare] session_closed {ex.GetType().Name}");
        }
        finally
        {
            try { _input?.ReleaseAll(); }
            catch (Exception) { Console.Error.WriteLine("[ScreenShare] input_release_failed"); }
            client.Dispose();
            lock (_gate) _client = null;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _stop.Cancel();
        _listener.Stop();
        lock (_gate) _client?.Dispose();
        _stop.Dispose();
        // AcceptLoopAsync awaits per-client cleanup before normal process exit.
    }
}
