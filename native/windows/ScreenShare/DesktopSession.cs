using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

static class DesktopSession
{
    public static void RequireInteractive()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows is required");
        using var process = Process.GetCurrentProcess();
        if (!Environment.UserInteractive || process.SessionId == 0)
            throw new UnauthorizedAccessException("Run in the owner's interactive Windows session, not a service");
        // OpenInputDesktop alone also succeeds in a disconnected session. Check WTS explicitly.
        if (!Native.WTSQuerySessionInformationW(IntPtr.Zero, process.SessionId, 8, out var state, out var bytes))
            throw new UnauthorizedAccessException("Cannot establish active session state");
        try
        {
            if (bytes < 4 || Marshal.ReadInt32(state) != 0)
                throw new UnauthorizedAccessException("Windows session is not active");
        }
        finally { Native.WTSFreeMemory(state); }
        if (Name(Native.GetProcessWindowStation()) != "WinSta0" ||
            Name(Native.GetThreadDesktop(Native.GetCurrentThreadId())) != "Default")
            throw new UnauthorizedAccessException("Only the interactive Default desktop may be shared");
        var desktop = Native.OpenInputDesktop(0, false, 1); // DESKTOP_READOBJECTS only
        if (desktop == IntPtr.Zero) throw new UnauthorizedAccessException("Input desktop is unavailable or protected");
        try
        {
            if (Name(desktop) != "Default")
                throw new UnauthorizedAccessException("Secure or alternate desktop cannot be shared");
        }
        finally { Native.CloseDesktop(desktop); }
    }

    private static string Name(IntPtr handle)
    {
        var name = new StringBuilder(256);
        if (handle == IntPtr.Zero || !Native.GetUserObjectInformationW(handle, 2, name, 512, out _))
            throw new UnauthorizedAccessException("Cannot verify desktop identity");
        return name.ToString();
    }
}
