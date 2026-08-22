defmodule OptimalSystemAgent.Shell.BackgroundTracker do
  @moduledoc """
  Tracks output files produced by background pentest commands.

  When the agent starts a long-running scan in the background (e.g.
  `nmap -sS -oN scan.txt 10.0.0.1`), it needs to know which files the command
  will write to, so it can:

  1. Wait for the process to finish before reading the output file
  2. Warn the agent if it tries to `file_read` a file that's still being written

  ## Output file extraction

  `extract_output_files/1` parses a command string for output targets using
  regex patterns adapted from HackerAI's `background-process-tracker.ts`:

    * `nmap -oN file`, `-oX file`, `-oG file` — Nmap output flags
    * `nmap -oA prefix` — creates prefix.nmap, prefix.xml, prefix.gnmap
    * `> file` or `>> file` — shell redirection
    * `| tee file` — tee to a file
    * `--output file` or `-o file` — generic output flags

  ## Usage

      # Extract output files from a command string
      files = BackgroundTracker.extract_output_files("nmap -sS -oN scan.txt 10.0.0.1")
      # => ["scan.txt"]

      files = BackgroundTracker.extract_output_files("nuclei -u https://example.com -o results.json")
      # => ["results.json"]

      files = BackgroundTracker.extract_output_files("nmap -sS -oA fullscan 10.0.0.1")
      # => ["fullscan.nmap", "fullscan.xml", "fullscan.gnmap"]

  ## Integration with BackgroundManager

  The agent should call `extract_output_files/1` when starting a background
  command, then check `is_output_file_writable?/2` before reading any file
  that might still be in use by a running background process.
  """

  @doc """
  Extract output file paths from a command string.

  Returns a deduplicated list of file paths the command will write to.
  Returns an empty list if no output targets are found.

  ## Examples

      iex> BackgroundTracker.extract_output_files("nmap -sS -oN scan.txt 10.0.0.1")
      ["scan.txt"]

      iex> BackgroundTracker.extract_output_files("echo hello")
      []

      iex> BackgroundTracker.extract_output_files("nmap -sS -oA fullscan 10.0.0.1")
      ["fullscan.nmap", "fullscan.xml", "fullscan.gnmap"]
  """
  @spec extract_output_files(String.t()) :: [String.t()]
  def extract_output_files(command) when is_binary(command) do
    []
    |> extract_nmap_output(command)
    |> extract_nmap_all_output(command)
    |> extract_shell_redirect(command)
    |> extract_tee(command)
    |> extract_generic_output(command)
    |> Enum.uniq()
  end

  def extract_output_files(_), do: []

  # ── Nmap output flags: -oN, -oX, -oG ──────────────────────────────────

  defp extract_nmap_output(acc, command) do
    # Match either a quoted string ("..." or '...') or a non-whitespace token
    # so filenames with spaces (nmap -oN "scan output.txt") are captured fully.
    patterns = [
      ~r/-oN\s+("[^"]+"|'[^']+'|[^\s]+)/,
      ~r/-oX\s+("[^"]+"|'[^']+'|[^\s]+)/,
      ~r/-oG\s+("[^"]+"|'[^']+'|[^\s]+)/
    ]

    files =
      Enum.flat_map(patterns, fn pattern ->
        Regex.scan(pattern, command, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&strip_quotes/1)
      end)

    acc ++ files
  end

  # ── Nmap -oA prefix (creates prefix.nmap, prefix.xml, prefix.gnmap) ──

  defp extract_nmap_all_output(acc, command) do
    case Regex.run(~r/-oA\s+([^\s]+)/, command, capture: :all_but_first) do
      [prefix] ->
        acc ++ ["#{prefix}.nmap", "#{prefix}.xml", "#{prefix}.gnmap"]

      _ ->
        acc
    end
  end

  # ── Shell redirection: > file, >> file ───────────────────────────────

  defp extract_shell_redirect(acc, command) do
    # Match > or >> preceded by whitespace or start, followed by a filename
    # Does NOT match 2> (stderr) or &> (both) — those are less common in
    # pentest output and including them would produce false positives.
    pattern = ~r/(?:^|[|;&])\s*[^|;&]*?\s+>>?\s+([^\s|;&]+)/

    files =
      Regex.scan(pattern, command, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&strip_quotes/1)

    acc ++ files
  end

  # ── tee: | tee file ──────────────────────────────────────────────────

  defp extract_tee(acc, command) do
    pattern = ~r/\|\s*tee\s+([^\s|;&]+)/

    files =
      Regex.scan(pattern, command, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&strip_quotes/1)

    acc ++ files
  end

  # ── Generic --output file or -o file ─────────────────────────────────

  defp extract_generic_output(acc, command) do
    patterns = [
      ~r/--output\s+([^\s]+)/,
      ~r/(?:^|\s)-o\s+([^\s]+)/
    ]

    files =
      Enum.flat_map(patterns, fn pattern ->
        Regex.scan(pattern, command, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&strip_quotes/1)
      end)

    acc ++ files
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp strip_quotes(str) do
    str |> String.trim(~s(")) |> String.trim(~s('))
  end

  @doc """
  Check if a file path is likely to be an output target of a command.

  Returns `true` if `file_path` matches any of the output files extracted
  from `command`. Uses normalized path comparison (strips leading `./`,
  normalizes slashes).

      iex> BackgroundTracker.is_output_target?("scan.txt", "nmap -oN scan.txt 10.0.0.1")
      true

      iex> BackgroundTracker.is_output_target?("other.txt", "nmap -oN scan.txt 10.0.0.1")
      false
  """
  @spec is_output_target?(String.t(), String.t()) :: boolean()
  def is_output_target?(file_path, command) when is_binary(file_path) and is_binary(command) do
    normalized_target = normalize_path(file_path)
    targets = Enum.map(extract_output_files(command), &normalize_path/1)

    Enum.any?(targets, fn target ->
      normalized_target == target or
        String.ends_with?(target, "/" <> normalized_target) or
        String.ends_with?(normalized_target, "/" <> target) or
        String.ends_with?(target, normalized_target) or
        String.ends_with?(normalized_target, target)
    end)
  end

  def is_output_target?(_, _), do: false

  @doc """
  Normalize a file path for comparison.

  Strips leading `./`, collapses multiple slashes, trims whitespace.

      iex> BackgroundTracker.normalize_path("./output/scan.txt")
      "output/scan.txt"

      iex> BackgroundTracker.normalize_path("/tmp//results//out.txt")
      "/tmp/results/out.txt"
  """
  @spec normalize_path(String.t()) :: String.t()
  def normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.replace(~r"\/+", "/")
    |> strip_leading_dot_slash()
  end

  def normalize_path(path), do: path

  defp strip_leading_dot_slash("./" <> rest), do: rest
  defp strip_leading_dot_slash(path), do: path
end
