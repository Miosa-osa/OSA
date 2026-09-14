using System.ComponentModel;
using System.Runtime.InteropServices;

readonly record struct DesktopBounds(int X, int Y, int Width, int Height);

sealed record DesktopFrame(int Width, int Height, byte[] Pixels)
{
    // At most 64 MiB per BGRA frame; no unbounded capture queue.
    public const int MaxPixels = 16 * 1024 * 1024;

    public void Validate()
    {
        if (Width <= 0 || Height <= 0 || Width > ushort.MaxValue || Height > ushort.MaxValue ||
            (long)Width * Height > MaxPixels || (long)Width * Height * 4 != Pixels.Length)
            throw new InvalidDataException("Unsupported framebuffer dimensions or byte count");
    }
}

// GDI is the compatibility capture backend, not a simulated DXGI fallback.
// All GDI handles are acquired, used and released on the same calling thread.
sealed class Capture
{
    public DesktopBounds Bounds { get; }
    private readonly int _displayIndex;

    public Capture(int displayIndex)
    {
        DesktopSession.RequireInteractive();
        _displayIndex = displayIndex;
        Bounds = GetBounds(displayIndex);
        if ((long)Bounds.Width * Bounds.Height > DesktopFrame.MaxPixels)
            throw new InvalidOperationException("Display exceeds 16 megapixel capture limit");
    }

    public DesktopFrame ReadFrame()
    {
        DesktopSession.RequireInteractive();
        if (GetBounds(_displayIndex) != Bounds)
            throw new InvalidOperationException("Display topology changed; start a new desktop session");
        IntPtr screen = IntPtr.Zero, memory = IntPtr.Zero, bitmap = IntPtr.Zero, previous = IntPtr.Zero;
        try
        {
            screen = Native.GetDC(IntPtr.Zero);
            if (screen == IntPtr.Zero) throw new Win32Exception();
            memory = Native.CreateCompatibleDC(screen);
            if (memory == IntPtr.Zero) throw new Win32Exception();
            var info = new Native.BitmapInfo
            {
                Size = 40,
                Width = Bounds.Width,
                Height = -Bounds.Height,
                Planes = 1,
                BitCount = 32
            };
            bitmap = Native.CreateDIBSection(screen, ref info, 0, out var bits, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero || bits == IntPtr.Zero) throw new Win32Exception();
            previous = Native.SelectObject(memory, bitmap);
            if (previous == IntPtr.Zero || previous == new IntPtr(-1)) throw new Win32Exception();
            // SRCCOPY | CAPTUREBLT includes layered windows, not protected content.
            if (!Native.BitBlt(memory, 0, 0, Bounds.Width, Bounds.Height,
                    screen, Bounds.X, Bounds.Y, 0x40CC0020)) throw new Win32Exception();
            DrawCursor(memory);
            if (!Native.GdiFlush()) throw new Win32Exception();
            var pixels = new byte[checked(Bounds.Width * Bounds.Height * 4)];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            DesktopSession.RequireInteractive();
            return new DesktopFrame(Bounds.Width, Bounds.Height, pixels);
        }
        finally
        {
            if (previous != IntPtr.Zero && previous != new IntPtr(-1)) Native.SelectObject(memory, previous);
            if (bitmap != IntPtr.Zero) Native.DeleteObject(bitmap);
            if (memory != IntPtr.Zero) Native.DeleteDC(memory);
            if (screen != IntPtr.Zero) Native.ReleaseDC(IntPtr.Zero, screen);
        }
    }

    private void DrawCursor(IntPtr dc)
    {
        var cursor = new Native.CursorInfo { Size = Marshal.SizeOf<Native.CursorInfo>() };
        if (!Native.GetCursorInfo(ref cursor) || (cursor.Flags & 1) == 0) return;
        if (!Native.GetIconInfo(cursor.Cursor, out var icon)) return;
        try
        {
            Native.DrawIconEx(dc, cursor.Position.X - Bounds.X - (int)icon.HotspotX,
                cursor.Position.Y - Bounds.Y - (int)icon.HotspotY, cursor.Cursor, 0, 0, 0, IntPtr.Zero, 3);
        }
        finally
        {
            if (icon.Mask != IntPtr.Zero) Native.DeleteObject(icon.Mask);
            if (icon.Color != IntPtr.Zero) Native.DeleteObject(icon.Color);
        }
    }

    internal static DesktopBounds GetBounds(int index)
    {
        var monitors = new List<(bool Primary, DesktopBounds Bounds)>();
        Native.MonitorCallback callback = (IntPtr monitor, IntPtr dc, ref Native.Rect rect, IntPtr data) =>
        {
            var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
            if (!Native.GetMonitorInfo(monitor, ref info)) return false;
            monitors.Add(((info.Flags & 1) != 0, new DesktopBounds(info.Monitor.Left, info.Monitor.Top,
                info.Monitor.Right - info.Monitor.Left, info.Monitor.Bottom - info.Monitor.Top)));
            return true;
        };
        if (!Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero))
            throw new Win32Exception();
        var ordered = monitors.OrderByDescending(m => m.Primary).ThenBy(m => m.Bounds.X)
            .ThenBy(m => m.Bounds.Y).ToArray();
        if (index < 0 || index >= ordered.Length) throw new ArgumentException("Display index is unavailable");
        var bounds = ordered[index].Bounds;
        if (bounds.Width <= 0 || bounds.Height <= 0) throw new InvalidOperationException("No active display");
        return bounds;
    }
}
