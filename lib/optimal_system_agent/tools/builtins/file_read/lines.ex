defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Lines do
  @moduledoc """
  Per-line length clamping for `file_read` output.

  ## Why this exists

  Line count is a terrible proxy for size. A minified bundle, a base64 blob
  pasted into a config, a single-line JSON dump or a CSV with an embedded
  newline-free payload can all be megabytes on **one** line. `offset`/`limit`
  give the caller no way to ask for less: `limit: 1` still returns the whole
  thing. That one line then goes out over the transport, blowing the result
  budget and, in the worst case, evicting the context that made the read useful.

  Clamping happens here, at the last point before the text leaves the tool. The
  marker is deliberately loud and states the real length, because a silently
  truncated line is worse than no line at all: the caller cannot tell that what
  it is reasoning about is a fragment.
  """

  alias OptimalSystemAgent.Tools.Ablation
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Constants

  @doc """
  Clamp every over-long line in `content`, preserving line structure.

  Content with no over-long line is returned by identity — the common case
  costs one newline-split scan and no rebuild.
  """
  @spec clamp(String.t()) :: String.t()
  def clamp(content) when is_binary(content) do
    cap = Constants.max_line_chars()

    # The ablation harness turns the cap off entirely to price it against the
    # transport blow-out it prevents. Production default is on; `Ablation.on?/1`
    # answers `true` for every live caller. See `Tools.Ablation`.
    if Ablation.on?(:read_line_clamp) and any_long_line?(content, cap) do
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {line, line_no} -> clamp_line(line, line_no, cap) end)
    else
      content
    end
  end

  @doc """
  Clamp a single line, tagging it with its 1-based `line_no` and true length.

  Returns the line unchanged when it is within the cap.
  """
  @spec clamp_line(String.t(), pos_integer(), pos_integer()) :: String.t()
  def clamp_line(line, line_no, cap \\ nil) when is_binary(line) do
    cap = cap || Constants.max_line_chars()

    # Cheap reject first: character count can never exceed byte count, so a line
    # within the cap in bytes is within the cap in characters, and the O(n)
    # `String.length/1` is skipped for every normal line in the file.
    if byte_size(line) <= cap do
      line
    else
      do_clamp_line(line, line_no, cap)
    end
  end

  defp do_clamp_line(line, line_no, cap) do
    length = String.length(line)

    if length <= cap do
      line
    else
      String.slice(line, 0, cap) <> marker(line_no, length, cap)
    end
  end

  defp marker(line_no, length, cap) do
    " ... [file_read clamped line #{line_no}: the line is #{length} characters long, " <>
      "only the first #{cap} are shown. This is a truncation, not the end of the line — " <>
      "do not treat it as complete. Use `file_grep` to search inside the full line, or " <>
      "`shell_execute` with `cut -c#{cap + 1}-#{cap * 2} <path>` to read the next slice.]"
  end

  # Byte-level scan: a line whose byte size is within the cap cannot have more
  # characters than the cap, so this never misses a line that needs clamping and
  # never decodes anything.
  defp any_long_line?(content, cap) do
    content
    |> :binary.split("\n", [:global])
    |> Enum.any?(fn line -> byte_size(line) > cap end)
  end
end
