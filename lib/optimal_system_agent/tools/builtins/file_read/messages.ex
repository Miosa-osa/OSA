defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Messages do
  @moduledoc """
  The text `file_read` returns when it cannot hand back file contents.

  ## Why this is its own module

  For a tool, the failure message *is* the feature. A caller that gets `error`,
  `:enoent` or "not valid UTF-8" has no move left except retrying the same call
  or abandoning the task; a caller told "the file has 12 lines, offset 500 is
  past the end" has an obvious next call. Every function here therefore obeys
  the same contract:

    1. name the file,
    2. state the specific fact that stopped the read — never a bare status,
       never a raw exception term,
    3. give a concrete next step, with the tool and arguments spelled out.

  Keeping them together makes that contract checkable, and lets the tests assert
  on the exact wording without reaching into read logic.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileRead.{Constants, PathResolve}

  @doc "The path is a directory. Different tool, not a different path."
  @spec directory(String.t()) :: String.t()
  def directory(display_path) do
    "#{display_path} is a directory, not a file. Use `dir_list` with " <>
      "`path: \"#{display_path}\"` to list its contents, or `file_glob`/`file_grep` " <>
      "to search inside it."
  end

  @doc """
  The path does not exist, and no Unicode-equivalent name existed either.

  Offers the closest real neighbours, because the overwhelmingly common cause is
  a near-miss — a typo, a wrong extension, a singular/plural directory — and a
  caller shown three real filenames fixes it in one step instead of probing.
  """
  @spec missing(String.t(), String.t()) :: String.t()
  def missing(display_path, expanded) do
    case PathResolve.suggestions(expanded, Constants.max_suggestions()) do
      {:no_parent, dir} ->
        "#{display_path} does not exist — and neither does its parent directory #{dir}, " <>
          "so nothing under that path can be read. Use `dir_list` on the nearest ancestor " <>
          "that does exist, or `file_glob` with `pattern: \"**/#{Path.basename(display_path)}\"` " <>
          "to find where the file actually lives."

      {:ok, []} ->
        dir = Path.dirname(expanded)

        "#{display_path} does not exist, and nothing in #{dir} has a similar name " <>
          "(this was also retried under Unicode NFC/NFD normalisation, in case the name " <>
          "differed only in encoding). Use `dir_list` with `path: \"#{dir}\"` to see what " <>
          "is actually there, or `file_glob` with " <>
          "`pattern: \"**/#{Path.basename(display_path)}\"` to search more widely."

      {:ok, names} ->
        dir = Path.dirname(expanded)

        "#{display_path} does not exist. The closest existing entries in #{dir} are: " <>
          "#{Enum.join(names, ", ")}. Retry `file_read` with the corrected path " <>
          "(entries ending in `/` are directories — use `dir_list` for those), or run " <>
          "`dir_list` with `path: \"#{dir}\"` for the full listing."
    end
  end

  @doc """
  The path is a FIFO, socket or device node.

  These are refused from `stat` alone, before any `open`. Opening a FIFO with no
  writer blocks forever, which surfaces as a hung agent rather than an error —
  the one failure mode with no diagnostic at all.
  """
  @spec special_file(String.t(), atom()) :: String.t()
  def special_file(display_path, :fifo) do
    "#{display_path} is a named pipe (FIFO), not a regular file. Opening it would block " <>
      "forever waiting for a writer, so `file_read` refuses it on the basis of `stat` " <>
      "without opening it. If you genuinely need its contents, use `shell_execute` with a " <>
      "bounded read such as `timeout 5 cat #{display_path}`, and make sure something is " <>
      "writing to the other end."
  end

  def special_file(display_path, :socket) do
    "#{display_path} is a Unix domain socket, not a regular file. Sockets cannot be read " <>
      "as files at all — no amount of retrying will change that. Talk to it with a client " <>
      "(`shell_execute` with `nc -U #{display_path}`), or read the log/output file the " <>
      "service behind it writes."
  end

  def special_file(display_path, :character_device) do
    "#{display_path} is a character device node, not a regular file. Reading one can block " <>
      "indefinitely or stream without end (`/dev/random`, `/dev/zero`), so `file_read` " <>
      "refuses it on the basis of `stat`. Use `shell_execute` with a bounded read such as " <>
      "`head -c 1024 #{display_path}` if you need a sample."
  end

  def special_file(display_path, :block_device) do
    "#{display_path} is a block device node, not a regular file. `file_read` will not read " <>
      "raw devices. Use `shell_execute` with a bounded read such as " <>
      "`head -c 1024 #{display_path}`, or `lsblk`/`blkid` if you wanted the device metadata."
  end

  def special_file(display_path, _other) do
    "#{display_path} is a special file, not a regular file (its `stat` type is neither a " <>
      "regular file nor a symlink to one). `file_read` refuses it because reading such a " <>
      "path can block indefinitely. Use `shell_execute` with `file #{display_path}` to see " <>
      "what it is, then a tool that suits it."
  end

  @doc """
  The file exists and is readable but has no bytes.

  Returned on the success channel, not as an error: an empty file is a fact
  about the file, not a failure of the read, and callers must still be able to
  edit or overwrite a file they have "read". The `<file_read notice: …>` wrapper
  exists so the text cannot be mistaken for content.
  """
  @spec empty_file(String.t()) :: String.t()
  def empty_file(display_path) do
    "<file_read notice: #{display_path} is empty (0 bytes) — this is the tool speaking, " <>
      "not file content>\n" <>
      "The file exists and is readable, but contains no bytes at all, so there are no " <>
      "lines to return. This is not a read failure and retrying it will return the same " <>
      "thing. If you expected content: confirm the path with `dir_list`, check whether the " <>
      "process that writes this file has actually run, or read the file you meant instead. " <>
      "The file counts as read, so you may now edit or overwrite it."
  end

  @doc """
  The exact bytes being asked for were already delivered to this session and
  have not changed since.

  Written to close the loop rather than to scold: it states the fact, says where
  the content already is, and says that retrying will not change the answer — a
  message that only said "unchanged" would invite the model to call again to find
  out what happened, which is the loop this exists to end.

  It is also kept **short on purpose**. The notice replaces the file's bytes, so
  every byte it spends is spent against the saving it exists to make; a verbose
  version measured 607 bytes, which is larger than many of the files it would
  replace. The handler additionally declines to substitute it for a file smaller
  than the notice itself — see `Handler.redundant_read/3`.

  ## How this composes with `eof_stamp/1` / `continuation_stamp/3`

  The two mechanisms answer different questions and are mutually exclusive by
  construction, so neither has to know about the other:

    * The stamps ride on **delivered content** and answer *"is there more after
      this window?"*. They are the only thing that addresses a walk of
      **different** windows, every one of which is a legitimately new question
      that suppression can never fire on.
    * This notice replaces content on a **byte-identical repeat** of a window
      already delivered. That window carried its own stamp when it was
      delivered, so the fact the notice points back to ("its content is already
      in your context above") includes the stamp. Restating it here would be
      duplicating a line the model already holds, to save nothing.

  One interaction is deliberate rather than incidental: `record_read/3` records
  the delivered byte count *including* the stamp, and `Handler.redundant_read/3`
  compares the notice against that figure. That is the correct comparison — the
  notice substitutes for the whole result, stamp included, so the stamp's bytes
  are genuinely part of what suppression saves.
  """
  @spec unchanged_since_last_read(String.t()) :: String.t()
  def unchanged_since_last_read(display_path) do
    "<file_read notice: #{display_path} is UNCHANGED since you last read it this session; " <>
      "its content is already in your context above and is current. Re-reading returns this " <>
      "notice, not bytes, until the file changes. The file counts as read — you may edit it.>"
  end

  @doc """
  Byte size of the shortest possible `unchanged_since_last_read/1` notice, used
  to decide whether substituting it would actually save anything.
  """
  @spec unchanged_notice_overhead() :: pos_integer()
  def unchanged_notice_overhead, do: byte_size(unchanged_since_last_read(""))

  @doc """
  Terminator stamp for a read that reached the last line of the file.

  ## Why this exists

  Measured on the `schemelike-metacircular-eval` head-to-head: 49 `file_read`
  calls against one path, each a *different* `offset`/`limit` window of the same
  growing file. Nothing in the result told the model where the window sat in the
  file or whether anything followed it, so the only way to find out was another
  read — and a model that cannot tell how much it is missing re-slices
  defensively.

  opencode has no duplicate-call detector at all and still measured **zero**
  duplicate calls on the same task. Its `tool/read.ts:344-350` always ends the
  result with one of these two stamps. The suppression this file already
  implements (`unchanged_since_last_read/1`) catches the *byte-identical* repeat;
  a stamp is what stops the near-miss window walk that suppression can never see,
  because every one of those calls has different arguments and is, strictly, a
  new question.

  Kept to one short line: it rides on every successful read, so unlike the
  unchanged-notice it is a cost paid on the success path, not a saving.
  """
  @spec eof_stamp(non_neg_integer()) :: String.t()
  def eof_stamp(total_lines) do
    "\n(End of file — #{total_lines} #{pluralise(total_lines, "line")} total)"
  end

  @doc """
  Terminator stamp for a read that stopped before the end of the file, naming
  the exact `offset` that continues it.

  The counterpart to `eof_stamp/1`: the model never has to guess a next offset,
  and never has to probe to discover it guessed wrong.
  """
  @spec continuation_stamp(pos_integer(), pos_integer(), pos_integer()) :: String.t()
  def continuation_stamp(first_line, last_line, next_offset) do
    "\n(Showing lines #{first_line}-#{last_line}. Use offset=#{next_offset} to continue.)"
  end

  @doc """
  Terminator stamp for a `byte_offset` slice.

  The byte axis needs its own stamp for the same reason the line axis does: the
  content of a slice cannot say whether it ended because the window filled up or
  because the file did. It names the next `byte_offset` so walking a long line
  is a sequence of exact calls rather than a sequence of guesses — which is the
  difference between "expensive" and "unrecoverable", and the whole reason the
  byte axis exists.
  """
  @spec byte_range_stamp(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: String.t()
  def byte_range_stamp(first_byte, last_byte, total_bytes) do
    if last_byte + 1 >= total_bytes do
      "\n(Bytes #{first_byte}-#{last_byte} of #{total_bytes} — end of file.)"
    else
      "\n(Bytes #{first_byte}-#{last_byte} of #{total_bytes}. " <>
        "Use byte_offset=#{last_byte + 1} to continue.)"
    end
  end

  @doc """
  The requested `byte_offset` starts at or after the last byte of the file.

  Names the file's real size, because the recoverable mistake here is asking
  from too far in — and the caller cannot know how far is too far without being
  told how big the file is.
  """
  @spec byte_offset_past_eof(String.t(), integer(), non_neg_integer()) :: String.t()
  def byte_offset_past_eof(display_path, byte_offset, total_bytes) do
    "byte_offset #{byte_offset} is at or past the end of #{display_path} — the file is " <>
      "#{total_bytes} #{pluralise(total_bytes, "byte")} long. Call `file_read` again with a " <>
      "byte_offset between 0 and #{max(total_bytes - 1, 0)}, or a negative byte_offset to " <>
      "read that many bytes from the end."
  end

  @doc """
  A `byte_offset` slice can cut a multi-byte character in half at either edge.

  Said once, plainly, so a lone replacement character at the start or end of a
  slice reads as an artefact of where the window landed rather than as content.
  """
  @spec byte_slice_utf8_note() :: String.t()
  def byte_slice_utf8_note do
    "\n(A byte window can start or end mid-character; any � at the edges is the cut, " <>
      "not the file. Shift byte_offset by a byte or two to realign.)"
  end

  @doc """
  The requested `offset` starts after the last line of the file.

  Distinct from an empty file, and the distinction is the whole point: one means
  "ask for a smaller offset", the other means "stop asking".
  """
  @spec past_eof(String.t(), integer(), non_neg_integer()) :: String.t()
  def past_eof(display_path, offset, total_lines) do
    "offset #{offset} is past the end of #{display_path} — the file has #{total_lines} " <>
      "#{pluralise(total_lines, "line")}, so there is nothing at or after line #{offset}. " <>
      "The file is not empty. Call `file_read` again using an offset between 1 and " <>
      "#{total_lines}, or omit `offset` to read from the start."
  end

  @doc """
  The file IS text — the head sniff says so — but the whole of it is not valid
  UTF-8, so somewhere past the sniff window there are bytes in another
  encoding.

  Distinct from `binary/2`, and the distinction is what makes it actionable:
  "this is a binary, use a different tool" is wrong advice for a latin-1 source
  file. One `iconv` pass makes it readable.

  Reaching this used to raise `FunctionClauseError` — `Magic.identify/1`
  returns the atom `:text` and `binary/2` only matches the `{:image, …}` and
  `{:binary, …}` tuples — so a latin-1 file whose first accented byte fell
  past the sniff window crashed the tool call instead of failing it.
  """
  @spec non_utf8_text(String.t()) :: String.t()
  def non_utf8_text(display_path) do
    "#{display_path} looks like text but is not valid UTF-8 — it is stored in another " <>
      "encoding (latin-1/cp1252 or similar), and the offending bytes are past the point " <>
      "where the leading-bytes check looks. `file_read` returns UTF-8 text only. Detect the " <>
      "encoding with `shell_execute` and `file -I #{display_path}`, then convert it with " <>
      "`iconv -f <that encoding> -t UTF-8 #{display_path}`. To see a slice without " <>
      "converting, call `file_read` again with `offset`/`limit` — undecodable bytes are " <>
      "shown as � there rather than refused."
  end

  @doc """
  Trailing note for an `offset`/`limit` slice that contained non-UTF-8 bytes.

  The slice is still returned — see `Handler.ensure_utf8/1` for why — so this
  explains the � the caller is looking at and how to get the real characters.
  """
  @spec non_utf8_slice_note() :: String.t()
  def non_utf8_slice_note do
    "[note: this file is not valid UTF-8 — it is stored in another encoding " <>
      "(latin-1/cp1252 or similar). Undecodable bytes are shown as �; line numbers and " <>
      "every other byte are unchanged. To read the real characters, convert first: " <>
      "`shell_execute` with `iconv -f <encoding> -t UTF-8 <path>`.]"
  end

  @doc """
  The bytes are not UTF-8 text, and `Magic` identified what they actually are.
  """
  @spec binary(String.t(), tuple()) :: String.t()
  def binary(display_path, {:image, media_type, label}) do
    exts = Enum.join(Constants.image_extensions(), ", ")

    "#{display_path} is not text: this is #{label} (#{media_type}), identified from its " <>
      "leading bytes rather than its name. `file_read` renders images only when the path " <>
      "ends in a recognised image extension (#{exts}), and this one does not. Copy it to " <>
      "such a path and read that (`shell_execute` with " <>
      "`cp #{display_path} #{display_path}#{default_ext(media_type)}`), or inspect it with " <>
      "`shell_execute` and `identify #{display_path}`."
  end

  def binary(display_path, {:binary, label, hint}) do
    "#{display_path} is not text: this is #{label}, identified from its leading bytes " <>
      "rather than its name. `file_read` returns text and images only. #{hint}"
  end

  @doc "The whole-file read would exceed the byte cap."
  @spec too_large(String.t(), float(), integer()) :: String.t()
  def too_large(display_path, mb, cap_mb) do
    "#{display_path} is too large to read whole (#{mb} MB, cap #{cap_mb} MB). Read a slice " <>
      "with `offset`/`limit`, or use `file_grep` to search inside it."
  end

  @doc "A path that resolved outside the allowlist after Unicode normalisation."
  @spec denied_after_normalisation(String.t(), String.t()) :: String.t()
  def denied_after_normalisation(display_path, resolved) do
    "Access denied: #{display_path} matches an existing file at #{resolved} under Unicode " <>
      "normalisation, but that path is outside the allowed read paths or is a sensitive " <>
      "file. Read a path inside the allowed roots instead."
  end

  defp pluralise(1, word), do: word
  defp pluralise(_, word), do: word <> "s"

  defp default_ext("image/png"), do: ".png"
  defp default_ext("image/jpeg"), do: ".jpg"
  defp default_ext("image/gif"), do: ".gif"
  defp default_ext("image/webp"), do: ".webp"
  defp default_ext("image/bmp"), do: ".bmp"
  defp default_ext("image/tiff"), do: ".tiff"
  defp default_ext(_), do: ".bin"
end
