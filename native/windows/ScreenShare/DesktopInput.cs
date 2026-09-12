using System.ComponentModel;
using System.Runtime.InteropServices;

interface IDesktopInput
{
    void Key(bool down, uint keysym);
    void Pointer(byte mask, int x, int y);
    void ReleaseAll();
}

// Input state belongs to one RFB connection. The native sink is the test seam;
// tests record actual Windows INPUT structures without touching any desktop.
sealed class DesktopInput : IDesktopInput
{
    private readonly Action<Native.Input> _send;
    private readonly DesktopBounds _display;
    private readonly Func<DesktopBounds> _virtualDesktop;
    private readonly Dictionary<uint, Native.Input[]> _held = new();
    private byte _buttons;
    private static readonly uint[] ButtonDown = { 0x2, 0x20, 0x8 };
    private static readonly uint[] ButtonUp = { 0x4, 0x40, 0x10 };

    internal DesktopInput(DesktopBounds display, Func<DesktopBounds> virtualDesktop, Action<Native.Input> send)
    { _display = display; _virtualDesktop = virtualDesktop; _send = send; }

    public static DesktopInput ForWindows(Capture capture, int displayIndex) => new(capture.Bounds,
        () => new DesktopBounds(Native.GetSystemMetrics(76), Native.GetSystemMetrics(77),
            Native.GetSystemMetrics(78), Native.GetSystemMetrics(79)), input =>
        {
            DesktopSession.RequireInteractive();
            if (Capture.GetBounds(displayIndex) != capture.Bounds)
                throw new InvalidOperationException("Display changed; input refused");
            if (Native.SendInput(1, new[] { input }, Marshal.SizeOf<Native.Input>()) != 1)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SendInput refused an event (possibly UIPI)");
        });

    public void Key(bool down, uint keysym)
    {
        if (!down)
        {
            if (_held.TryGetValue(keysym, out var held))
            {
                foreach (var input in held.Reverse()) _send(KeyUp(input));
                _held.Remove(keysym);
            }
            return;
        }
        if (_held.TryGetValue(keysym, out var repeat))
        {
            foreach (var input in repeat) _send(input);
            return;
        }
        if (_held.Count >= 128) throw new InvalidDataException("Too many held keys");
        var shortcut = _held.Keys.Any(k => k is 0xffe3 or 0xffe4 or 0xffe9 or 0xffea or 0xffeb or 0xffec or 0xffe7 or 0xffe8 or 0xfe03);
        var events = KeyMap.Map(keysym, shortcut);
        if (events.Length == 0) return;
        // Track before sending so a partially failed Unicode pair is still released.
        _held.Add(keysym, events);
        foreach (var input in events) _send(input);
    }

    public void Pointer(byte mask, int x, int y)
    {
        if (x < 0 || y < 0 || x >= _display.Width || y >= _display.Height)
            throw new InvalidDataException("Pointer is outside the shared display");
        var desktop = _virtualDesktop();
        if (desktop.Width <= 0 || desktop.Height <= 0) throw new InvalidOperationException("No virtual desktop");
        var dx = (int)((long)(_display.X + x - desktop.X) * 65535 / Math.Max(1, desktop.Width - 1));
        var dy = (int)((long)(_display.Y + y - desktop.Y) * 65535 / Math.Max(1, desktop.Height - 1));
        if (dx is < 0 or > 65535 || dy is < 0 or > 65535) throw new InvalidOperationException("Display topology changed");
        _send(Mouse(0xC001, 0, dx, dy)); // MOVE | ABSOLUTE | VIRTUALDESK
        var old = _buttons;
        for (var i = 0; i < 3; i++)
        {
            var bit = (byte)(1 << i);
            if ((mask & bit) == (old & bit)) continue;
            // Keep cleanup state if SendInput fails part way through a packet.
            if ((mask & bit) != 0) _buttons |= bit;
            _send(Mouse((mask & bit) != 0 ? ButtonDown[i] : ButtonUp[i]));
            if ((mask & bit) == 0) _buttons &= (byte)~bit;
        }
        for (var i = 3; i <= 6; i++)
            if ((mask & (1 << i)) != 0 && (old & (1 << i)) == 0)
                _send(Mouse(i < 5 ? 0x800u : 0x1000u,
                    unchecked((uint)(i is 3 or 6 ? 120 : -120))));
        _buttons = mask;
    }

    public void ReleaseAll()
    {
        Exception? failure = null;
        foreach (var key in _held.Values.Reverse())
            foreach (var input in key.Reverse())
                try { _send(KeyUp(input)); } catch (Exception ex) { failure ??= ex; }
        _held.Clear();
        for (var i = 0; i < 3; i++)
            if ((_buttons & (1 << i)) != 0)
                try { _send(Mouse(ButtonUp[i])); } catch (Exception ex) { failure ??= ex; }
        _buttons = 0;
        if (failure != null) throw new InvalidOperationException("Could not release every remote input", failure);
    }

    private static Native.Input KeyUp(Native.Input input)
    { input.Data.Keyboard.Flags |= 2; return input; }
    private static Native.Input Mouse(uint flags, uint data = 0, int x = 0, int y = 0) => new()
    { Type = 0, Data = new Native.InputUnion { Mouse = new Native.MouseInput { X = x, Y = y, Flags = flags, Data = data } } };
}

static class KeyMap
{
    internal static Native.Input[] Map(uint keysym, bool shortcut)
    {
        // X11 keysyms from RFB are not Windows virtual-key numbers.
        (ushort Vk, bool Extended) key = keysym switch
        {
            0xff08 => (0x08, false),
            0xff09 or 0xfe20 => (0x09, false),
            0xff0d => (0x0d, false),
            0xff1b => (0x1b, false),
            0xff13 => (0x13, false),
            0xff14 => (0x91, false),
            0xff50 => (0x24, true),
            0xff51 => (0x25, true),
            0xff52 => (0x26, true),
            0xff53 => (0x27, true),
            0xff54 => (0x28, true),
            0xff55 => (0x21, true),
            0xff56 => (0x22, true),
            0xff57 => (0x23, true),
            0xff63 => (0x2d, true),
            0xffff => (0x2e, true),
            0xff61 => (0x2c, true),
            0xff67 => (0x5d, true),
            0xffe1 => (0xa0, false),
            0xffe2 => (0xa1, false),
            0xffe3 => (0xa2, false),
            0xffe4 => (0xa3, true),
            0xffe5 => (0x14, false),
            0xffe9 => (0xa4, false),
            0xffea or 0xfe03 => (0xa5, true),
            0xffeb or 0xffe7 => (0x5b, true),
            0xffec or 0xffe8 => (0x5c, true),
            0xff7f => (0x90, true),
            0xff8d => (0x0d, true),
            0xff80 => (0x20, false),
            0xff89 => (0x09, false),
            0xff95 => (0x24, false),
            0xff96 => (0x25, false),
            0xff97 => (0x26, false),
            0xff98 => (0x27, false),
            0xff99 => (0x28, false),
            0xff9a => (0x21, false),
            0xff9b => (0x22, false),
            0xff9c => (0x23, false),
            0xff9d => (0x0c, false),
            0xff9e => (0x2d, false),
            0xff9f => (0x2e, false),
            0xffac => (0x6c, false),
            0xffaa => (0x6a, false),
            0xffab => (0x6b, false),
            0xffad => (0x6d, false),
            0xffae => (0x6e, false),
            0xffaf => (0x6f, true),
            >= 0xffb0 and <= 0xffb9 => ((ushort)(0x60 + keysym - 0xffb0), false),
            >= 0xffbe and <= 0xffd5 => ((ushort)(0x70 + keysym - 0xffbe), false),
            _ => (0, false)
        };
        if (key.Vk != 0) return new[] { Keyboard(key.Vk, 0, key.Extended ? 1u : 0u) };
        if (shortcut && keysym is >= 0x20 and <= 0x7e)
        {
            // Letters, digits and space have stable VKs for Ctrl/Alt/Windows shortcuts.
            // Punctuation uses Unicode, never a US-layout guessed OEM key.
            if (keysym is >= 'a' and <= 'z') keysym -= 32;
            if (keysym is >= 'A' and <= 'Z' or >= '0' and <= '9' or 0x20)
                return new[] { Keyboard((ushort)keysym, 0, 0) };
        }
        uint scalar = (keysym & 0xff000000) == 0x01000000 ? keysym & 0x00ffffff : keysym;
        if (scalar < 0x20 || scalar > 0x10ffff || scalar is >= 0xd800 and <= 0xdfff ||
            ((keysym & 0xff000000) != 0x01000000 && keysym > 0xff)) return Array.Empty<Native.Input>();
        return char.ConvertFromUtf32((int)scalar).Select(c => Keyboard(0, c, 4)).ToArray();
    }

    private static Native.Input Keyboard(ushort vk, ushort scan, uint flags) => new()
    { Type = 1, Data = new Native.InputUnion { Keyboard = new Native.KeyboardInput { Vk = vk, Scan = scan, Flags = flags } } };
}
