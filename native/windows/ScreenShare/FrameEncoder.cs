/// FrameEncoder.cs — RFB 3.8 protocol byte helpers.
///
/// Mirrors the logic in the macOS Swift FrameEncoder.swift.
/// All multi-byte integers are big-endian as required by RFC 6143.

using System;
using System.Text;

static class FrameEncoder
{
    // ---- Handshake ----------------------------------------------------------

    public static byte[] ProtocolVersion()
        => Encoding.ASCII.GetBytes("RFB 003.008\n");

    /// Security types message: count=1, type=1 (None)
    public static byte[] SecurityTypes()
        => new byte[] { 1, 1 };

    /// Security result: OK (uint32 BE = 0)
    public static byte[] SecurityResult()
        => new byte[] { 0, 0, 0, 0 };

    // ---- ServerInit ---------------------------------------------------------

    public static byte[] ServerInit(int width, int height, string name = "ScreenShare")
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        // 2+2 (w,h) + 16 (pixel format) + 4 (name length) + name
        var msg = new byte[2 + 2 + 16 + 4 + nameBytes.Length];
        int i = 0;

        // Width, height (BE uint16)
        WriteU16(msg, ref i, (ushort)width);
        WriteU16(msg, ref i, (ushort)height);

        // ServerPixelFormat (16 bytes):
        //   bits_per_pixel=32, depth=24, big_endian=0, true_colour=1
        //   red_max=255, green_max=255, blue_max=255
        //   red_shift=16, green_shift=8, blue_shift=0
        //   3 padding bytes
        msg[i++] = 32;   // bpp
        msg[i++] = 24;   // depth
        msg[i++] = 0;    // big-endian flag (0 = little-endian)
        msg[i++] = 1;    // true-colour flag
        WriteU16(msg, ref i, 255);  // red max
        WriteU16(msg, ref i, 255);  // green max
        WriteU16(msg, ref i, 255);  // blue max
        msg[i++] = 16;  // red shift
        msg[i++] = 8;   // green shift
        msg[i++] = 0;   // blue shift
        msg[i++] = 0; msg[i++] = 0; msg[i++] = 0; // padding

        // Name length + name
        WriteU32(msg, ref i, (uint)nameBytes.Length);
        nameBytes.CopyTo(msg, i);

        return msg;
    }

    // ---- FramebufferUpdate --------------------------------------------------

    /// FramebufferUpdate with a single raw-encoded rectangle.
    public static byte[] FramebufferUpdate(int x, int y, int width, int height, byte[] pixelData)
    {
        // Header: type(1) + pad(1) + rect_count(2) = 4 bytes
        // Rect:   x(2)+y(2)+w(2)+h(2)+encoding(4) = 12 bytes
        // Total header = 16 bytes + pixel data
        var header = new byte[16];
        int i = 0;

        header[i++] = 0;  // message type: FramebufferUpdate
        header[i++] = 0;  // padding
        WriteU16(header, ref i, 1);  // number of rectangles

        WriteU16(header, ref i, (ushort)x);
        WriteU16(header, ref i, (ushort)y);
        WriteU16(header, ref i, (ushort)width);
        WriteU16(header, ref i, (ushort)height);
        WriteU32(header, ref i, 0);  // encoding: Raw (0)

        var msg = new byte[header.Length + pixelData.Length];
        header.CopyTo(msg, 0);
        pixelData.CopyTo(msg, header.Length);
        return msg;
    }

    // ---- Helpers ------------------------------------------------------------

    public static void WriteU16(byte[] buf, ref int offset, ushort value)
    {
        buf[offset++] = (byte)(value >> 8);
        buf[offset++] = (byte)(value & 0xFF);
    }

    public static void WriteU32(byte[] buf, ref int offset, uint value)
    {
        buf[offset++] = (byte)(value >> 24);
        buf[offset++] = (byte)((value >> 16) & 0xFF);
        buf[offset++] = (byte)((value >> 8)  & 0xFF);
        buf[offset++] = (byte)(value & 0xFF);
    }

    public static ushort ReadU16(byte[] buf, int offset)
        => (ushort)((buf[offset] << 8) | buf[offset + 1]);

    public static uint ReadU32(byte[] buf, int offset)
        => (uint)((buf[offset] << 24) | (buf[offset+1] << 16) | (buf[offset+2] << 8) | buf[offset+3]);
}
