using System.Globalization;

sealed record Config(int Port, int DisplayIndex, bool AllowInput)
{
    public static Config Parse(string[] args)
    {
        int port = 0, display = 0;
        bool allowInput = false;
        var seen = new HashSet<string>();
        for (int i = 0; i < args.Length; i++)
        {
            var option = args[i];
            if (!seen.Add(option)) throw new ArgumentException($"Repeated option: {option}");
            switch (option)
            {
                case "--allow-input": allowInput = true; break;
                case "--read-only": break;
                case "--port":
                case "--display":
                    if (++i == args.Length || !int.TryParse(args[i], NumberStyles.None,
                            CultureInfo.InvariantCulture, out var value))
                        throw new ArgumentException($"Missing or invalid value for {option}");
                    if (option == "--port") port = value; else display = value;
                    break;
                default: throw new ArgumentException($"Unknown option: {option}");
            }
        }
        if (port is < 0 or > 65535 || display is < 0 or > 63)
            throw new ArgumentException("Port must be 0..65535 and display 0..63");
        if (seen.Contains("--allow-input") && seen.Contains("--read-only"))
            throw new ArgumentException("Conflicting input permissions");
        return new Config(port, display, allowInput);
    }
}
