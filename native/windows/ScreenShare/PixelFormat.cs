readonly record struct PixelFormat(int BytesPerPixel, bool BigEndian, int RedMax, int GreenMax,
    int BlueMax, int RedShift, int GreenShift, int BlueShift)
{
    public static PixelFormat Default => new(4, false, 255, 255, 255, 16, 8, 0);

    public static PixelFormat Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != 16 || bytes[0] is not (8 or 16 or 32) || bytes[1] == 0 ||
            bytes[1] > bytes[0] || bytes[2] > 1 || bytes[3] != 1)
            throw new InvalidDataException("Only 8/16/32-bit true-colour formats are supported");
        var r = (bytes[4] << 8) | bytes[5]; var g = (bytes[6] << 8) | bytes[7];
        var b = (bytes[8] << 8) | bytes[9];
        static bool ValidMax(int value) => value > 0 && (value & (value + 1)) == 0;
        if (!ValidMax(r) || !ValidMax(g) || !ValidMax(b) || bytes[10] >= bytes[0] ||
            bytes[11] >= bytes[0] || bytes[12] >= bytes[0]) throw new InvalidDataException("Invalid colour masks");
        ulong rm = (ulong)r << bytes[10], gm = (ulong)g << bytes[11], bm = (ulong)b << bytes[12];
        if ((rm | gm | bm) >= (1ul << bytes[0]) || (rm & gm) != 0 || (rm & bm) != 0 || (gm & bm) != 0 ||
            System.Numerics.BitOperations.PopCount(rm | gm | bm) > bytes[1])
            throw new InvalidDataException("Overlapping or out-of-range colour masks");
        return new(bytes[0] / 8, bytes[2] == 1, r, g, b, bytes[10], bytes[11], bytes[12]);
    }

    public void Encode(ReadOnlySpan<byte> bgra, Span<byte> output)
    {
        if (bgra.Length % 4 != 0 || output.Length != bgra.Length / 4 * BytesPerPixel)
            throw new ArgumentException("Pixel buffer sizes do not match");
        for (int i = 0, dest = 0; i < bgra.Length; i += 4, dest += BytesPerPixel)
        {
            uint pixel = ((uint)(bgra[i + 2] * RedMax / 255) << RedShift) |
                ((uint)(bgra[i + 1] * GreenMax / 255) << GreenShift) |
                ((uint)(bgra[i] * BlueMax / 255) << BlueShift);
            for (int n = 0; n < BytesPerPixel; n++)
                output[dest + n] = (byte)(pixel >> (8 * (BigEndian ? BytesPerPixel - n - 1 : n)));
        }
    }
}
