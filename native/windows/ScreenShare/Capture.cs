/// Capture.cs — Windows Desktop Duplication API wrapper.
///
/// Uses DXGI OutputDuplication + Direct3D 11 to grab frames from the primary
/// (or indexed) display adapter output. Converts each frame to BGR24 bytes and
/// pushes them to VncServer.SetFrame().
///
/// Phase 1 status: skeleton. `Start()` currently falls back to stub mode after
/// logging the capture_error so the overall pipeline is testable.
///
/// What a Phase 2 specialist needs to complete (search TODO:P2):
///   1. Real D3D11 device + DXGI output enumeration
///   2. OutputDuplication.AcquireNextFrame() loop
///   3. Staging texture + Map/Unmap to read CPU-accessible pixels
///   4. BGRA → BGR24 conversion matching VncServer.PixelFormat
///   5. Handle OutputDuplication recreation on DXGI_ERROR_ACCESS_LOST
///   6. Multi-monitor: enumerate IDXGIOutput per IDXGIAdapter

using System;
using System.Threading;

// TODO:P2 — add `using Vortice.DXGI;` and `using Vortice.Direct3D11;`
// after installing Vortice.DXGI + Vortice.Direct3D11 NuGet packages.
// Skeleton compiles today without them; swap the TODO stubs for real calls.

sealed class Capture
{
    private readonly VncServer _server;
    private readonly int       _displayIndex;
    private volatile bool      _running;

    public Capture(VncServer server, int displayIndex)
    {
        _server       = server;
        _displayIndex = displayIndex;
    }

    /// <summary>
    /// Starts the Desktop Duplication capture loop.
    /// Runs until <paramref name="token"/> is cancelled or a non-recoverable
    /// DXGI error occurs. Falls back to stub on first error.
    /// </summary>
    public void Start(CancellationToken token)
    {
        _running = true;
        try
        {
            StartInternal(token);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ScreenShare] capture_error {ex.Message} — falling back to stub");
            // VncServer already serves stub frames by default; nothing to do.
        }
        finally
        {
            _running = false;
        }
    }

    public void Stop() => _running = false;

    // -------------------------------------------------------------------------
    // Internal — Desktop Duplication loop
    // -------------------------------------------------------------------------

    private void StartInternal(CancellationToken token)
    {
        // TODO:P2 — Real implementation:
        //
        //   1. Create D3D11 device:
        //      D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.None,
        //          featureLevels, out var device, out _, out var context);
        //
        //   2. Get DXGI device + adapter:
        //      using var dxgiDevice = device.QueryInterface<IDXGIDevice>();
        //      using var adapter    = dxgiDevice.GetParent<IDXGIAdapter>();
        //
        //   3. Enumerate outputs, pick _displayIndex:
        //      adapter.EnumOutputs(_displayIndex, out var output);
        //      using var output1 = output.QueryInterface<IDXGIOutput1>();
        //
        //   4. Create output duplication:
        //      output1.DuplicateOutput(device, out var duplication);
        //
        //   5. Frame loop:
        //      while (!token.IsCancellationRequested)
        //      {
        //          var hr = duplication.AcquireNextFrame(33, out var info, out var resource);
        //          if (hr == DXGI_ERROR_WAIT_TIMEOUT) continue;
        //          if (hr == DXGI_ERROR_ACCESS_LOST)  { /* recreate duplication */ continue; }
        //
        //          using var texture2d = resource.QueryInterface<ID3D11Texture2D>();
        //          var desc = texture2d.Description;
        //          desc.Usage     = ResourceUsage.Staging;
        //          desc.BindFlags = BindFlags.None;
        //          desc.CPUAccessFlags = CpuAccessFlags.Read;
        //          device.CreateTexture2D(desc, null, out var staging);
        //
        //          context.CopyResource(staging, texture2d);
        //          var mapped = context.Map(staging, 0, MapMode.Read, 0);
        //
        //          // Convert BGRA → BGR24 and hand to VncServer
        //          var frame = ConvertBgraToBgr24(mapped, desc.Width, desc.Height, mapped.RowPitch);
        //          _server.SetFrame(desc.Width, desc.Height, frame);
        //
        //          context.Unmap(staging, 0);
        //          duplication.ReleaseFrame();
        //      }
        //
        // Console.Error.WriteLine($"[ScreenShare] capture_started display={_displayIndex} {w}x{h}");

        // Stub fallthrough — remove once real capture is wired:
        throw new NotImplementedException("Desktop Duplication capture not yet implemented (Phase 2)");
    }

    // TODO:P2 — Implement pixel format conversion
    private static byte[] ConvertBgraToBgr24(object /*MappedSubresource*/ mapped, int width, int height, int rowPitch)
    {
        // Each BGRA pixel is 4 bytes; drop the A channel.
        var result = new byte[width * height * 3];
        // TODO:P2 — unsafe pointer walk over mapped.DataPointer
        return result;
    }
}
