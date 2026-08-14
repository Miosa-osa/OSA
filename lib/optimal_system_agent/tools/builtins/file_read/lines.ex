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

  ## The marker names its own undo

  Measured by `mix osa.ablate`: with the clamp on, three facts in the hostile
  corpus were not merely expensive to get, they were **unrecoverable** — the end
  of a minified file, a base64 blob's decodability, and a deep JSON leaf. There
  was no call, in any tool, that could ask for the tail of a clamped line.
  `offset`/`limit` address LINES, and the line in question was already fully
  selected.

  That is what makes a truncation different from a window: a window says where
  to continue, so it costs a call; a truncation that cannot say where to
  continue costs the fact. So every marker now carries the absolute byte offset
  at which it stopped, which is a `file_read` `byte_offset` argument the caller
  can use verbatim. Threading that offset is why `clamp/1` and `clamp_line/2`
  take a base offset at all — the character cap is not a byte cap, so the resume
  point has to be computed from the bytes the cap actually consumed rather than
  from the cap itself.
  """

  alias OptimalSystemAgent.Tools.Ablation
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Constants

  @doc """
  Clamp every over-long line in `content`, preserving line structure.

  `base_offset` is the absolute byte offset of the first line within the file,
  so each marker can name a real `byte_offset`. Defaults to 0, which is correct
  for the whole-file read this is called from.

  Content with no over-long line is returned by identity — the common case
  costs one newline-split scan and no rebuild.
  """
  @spec clamp(String.t(), non_neg_integer()) :: String.t()
  def clamp(content, base_offset \\ 0) when is_binary(content) do
    cap = Constants.max_line_chars()

    # The ablation harness turns the cap off entirely to price it against the
    # transport blow-out it prevents. Production default is on; `Ablation.on?/1`
    # answers `true` for every live caller. See `Tools.Ablation`.
    if Ablation.on?(:read_line_clamp) and any_long_line?(content, cap) do
      {clamped, _} =
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.map_reduce(base_offset, fn {line, line_no}, offset ->
          # +1 for the newline `String.split/2` consumed. The last line of a
          # file with no trailing newline over-counts the final offset by one,
          # which nothing reads.
          {clamp_line(line, line_no, cap, offset), offset + byte_size(line) + 1}
        end)

      Enum.join(clamped, "\n")
    else
      content
    end
  end

  @doc """
  Clamp a single line, tagging it with its 1-based `line_no` and true length.

  `line_offset` is the line's absolute byte offset in the file; when it is `nil`
  the marker still says the line was truncated and still names `byte_offset` as
  the way out, it just cannot compute the exact resume point.

  Returns the line unchanged when it is within the cap.
  """
  @spec clamp_line(String.t(), pos_integer(), pos_integer() | nil, non_neg_integer() | nil) ::
          String.t()
  def clamp_line(line, line_no, cap \\ nil, line_offset \\ nil) when is_binary(line) do
    cap = cap || Constants.max_line_chars()

    # Cheap reject first: character count can never exceed byte count, so a line
    # within the cap in bytes is within the cap in characters, and the O(n)
    # `String.length/1` is skipped for every normal line in the file.
    if byte_size(line) <= cap do
      line
    else
      do_clamp_line(line, line_no, cap, line_offset)
    end
  end

  defp do_clamp_line(line, line_no, cap, line_offset) do
    length = String.length(line)

    if length <= cap do
      line
    else
      kept = String.slice(line, 0, cap)
      kept <> marker(line_no, length, cap, resume_offset(line_offset, kept))
    end
  end

  # The cap counts CHARACTERS and `byte_offset` counts bytes; for anything
  # outside ASCII those differ, so the resume point is measured from the slice
  # that was actually kept rather than assumed to be `line_offset + cap`. An
  # off-by-a-few-bytes resume would land mid-codepoint and hand the caller a
  # replacement character where the real content should start.
  defp resume_offset(nil, _kept), do: nil
  defp resume_offset(line_offset, kept), do: line_offset + byte_size(kept)

  defp marker(line_no, length, cap, resume) do
    " ... [file_read clamped line #{line_no}: the line is #{length} characters long, " <>
      "only the first #{cap} are shown. This is a truncation, not the end of the line — " <>
      "do not treat it as complete. " <> recovery(resume) <> "]"
  end

  defp recovery(nil) do
    "To read the rest, call file_read with `byte_offset` (raw bytes, not lines); " <>
      "a negative `byte_offset` reads from the end of the file."
  end

  defp recovery(resume) do
    "To read the rest, call file_read with `byte_offset: #{resume}` — that is the exact " <>
      "byte this stopped at, and each slice names the next one. `byte_offset: -2000` reads " <>
      "the last 2000 bytes instead."
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
