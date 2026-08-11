defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Magic do
  @moduledoc """
  Content-based file-type identification for `file_read`.

  ## Why this exists

  When `file_read` refuses a file, the refusal has to tell the caller what the
  file actually *is*. "appears to be a binary or non-UTF-8 file" is a dead end:
  it names a property the caller already suspected and suggests nothing. "this
  is a ZIP archive" is a next step, because the caller immediately knows to
  reach for `unzip -l` instead of retrying the same read.

  Identification is done from the leading bytes, never from the extension.
  Extensions are frequently absent (`/tmp/download`), wrong (a `.txt` holding
  PNG bytes), or misleading (`.dat`), and the whole point of this module is to
  be right in exactly those cases.

  ## Strong vs weak signatures

  Signatures are checked in two tiers.

  * **Strong** signatures contain control bytes or are long enough that no
    plausible text file could begin with them (`\\x89PNG\\r\\n`, `%PDF-`,
    `SQLite format 3\\0`). They win outright.
  * **Weak** signatures are short ASCII runs that a real text file could
    legitimately start with — `MZ`, `BM`, `ID3`, `PACK` (as in `PACKAGE`).
    Those are only consulted *after* the content has already been judged
    non-text, so a prose file opening with "ID3 tags are…" is still read as
    prose instead of being refused as an MP3.

  `identify/1` is total: anything matching nothing falls back to a UTF-8/NUL
  heuristic, so the caller always gets either `:text` or a labelled binary
  verdict.
  """

  @typedoc """
  * `{:image, media_type, label}` — a recognised image format
  * `{:binary, label, hint}`      — not text; `label` names it, `hint` says what to do
  * `:text`                       — the sniffed prefix looks like UTF-8 text
  """
  @type verdict ::
          {:image, String.t(), String.t()}
          | {:binary, String.t(), String.t()}
          | :text

  @doc """
  Identify a file from its leading bytes.

  Pass at least the first few hundred bytes; `Constants.sniff_bytes/0` worth is
  what `file_read` supplies. Never pass a whole multi-megabyte file — nothing
  below looks past offset 262.
  """
  @spec identify(binary()) :: verdict()
  def identify(bytes) when is_binary(bytes) do
    strong(bytes) || tar(bytes) || weak_or_text(bytes)
  end

  # ── Strong: images ────────────────────────────────────────────────────

  defp strong(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>),
    do: {:image, "image/png", "a PNG image"}

  defp strong(<<0xFF, 0xD8, 0xFF, _::binary>>),
    do: {:image, "image/jpeg", "a JPEG image"}

  defp strong(<<"GIF87a", _::binary>>), do: {:image, "image/gif", "a GIF image"}
  defp strong(<<"GIF89a", _::binary>>), do: {:image, "image/gif", "a GIF image"}

  defp strong(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>),
    do: {:image, "image/webp", "a WebP image"}

  defp strong(<<"II", 0x2A, 0x00, _::binary>>), do: {:image, "image/tiff", "a TIFF image"}
  defp strong(<<"MM", 0x00, 0x2A, _::binary>>), do: {:image, "image/tiff", "a TIFF image"}

  defp strong(<<0x00, 0x00, 0x01, 0x00, _::binary>>),
    do: {:binary, "a Windows ICO icon", shell_hint("`identify <path>` or an image viewer")}

  # ── Strong: non-UTF-8 text encodings ──────────────────────────────────
  # Worth naming separately from "binary": the bytes *are* text, the caller
  # just needs one transcode step rather than a different tool entirely.

  defp strong(<<0xFF, 0xFE, 0x00, 0x00, _::binary>>),
    do:
      {:binary, "UTF-32LE text — a non-UTF-8 encoding (byte-order mark FF FE 00 00)",
       iconv_hint("UTF-32LE")}

  defp strong(<<0x00, 0x00, 0xFE, 0xFF, _::binary>>),
    do:
      {:binary, "UTF-32BE text — a non-UTF-8 encoding (byte-order mark 00 00 FE FF)",
       iconv_hint("UTF-32BE")}

  defp strong(<<0xFF, 0xFE, _::binary>>),
    do:
      {:binary, "UTF-16LE text — a non-UTF-8 encoding (byte-order mark FF FE)",
       iconv_hint("UTF-16LE")}

  defp strong(<<0xFE, 0xFF, _::binary>>),
    do:
      {:binary, "UTF-16BE text — a non-UTF-8 encoding (byte-order mark FE FF)",
       iconv_hint("UTF-16BE")}

  # ── Strong: archives & compression ────────────────────────────────────

  defp strong(<<"PK", 0x03, 0x04, _::binary>>), do: zip_verdict()
  defp strong(<<"PK", 0x05, 0x06, _::binary>>), do: zip_verdict()
  defp strong(<<"PK", 0x07, 0x08, _::binary>>), do: zip_verdict()

  defp strong(<<0x1F, 0x8B, _::binary>>),
    do:
      {:binary, "gzip-compressed data",
       shell_hint("`gzip -dc <path>` (or `tar -tzf <path>` if it is a .tar.gz)")}

  defp strong(<<"BZh", d, _::binary>>) when d >= ?1 and d <= ?9,
    do: {:binary, "bzip2-compressed data", shell_hint("`bzip2 -dc <path>`")}

  defp strong(<<0xFD, "7zXZ", 0x00, _::binary>>),
    do: {:binary, "xz-compressed data", shell_hint("`xz -dc <path>`")}

  defp strong(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>>),
    do: {:binary, "zstd-compressed data", shell_hint("`zstd -dc <path>`")}

  defp strong(<<"7z", 0xBC, 0xAF, 0x27, 0x1C, _::binary>>),
    do: {:binary, "a 7-Zip archive", shell_hint("`7z l <path>`")}

  defp strong(<<"Rar!", 0x1A, 0x07, _::binary>>),
    do: {:binary, "a RAR archive", shell_hint("`unrar l <path>`")}

  defp strong(<<"!<arch>\n", _::binary>>),
    do:
      {:binary, "a Unix ar archive (a .a static library or a .deb package)",
       shell_hint("`ar t <path>`")}

  # ── Strong: documents & databases ─────────────────────────────────────

  defp strong(<<"%PDF-", _::binary>>),
    do: {:binary, "a PDF document", shell_hint("`pdftotext <path> -` to extract its text")}

  defp strong(<<"SQLite format 3", 0x00, _::binary>>),
    do:
      {:binary, "a SQLite database",
       shell_hint("`sqlite3 <path> .schema` for the schema, or `.dump` for the contents")}

  defp strong(<<"{\\rtf", _::binary>>),
    do: {:binary, "an RTF document", shell_hint("`unrtf --text <path>`")}

  defp strong(<<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, _::binary>>),
    do:
      {:binary, "a legacy Microsoft Office document (OLE2 compound file: .doc/.xls/.ppt)",
       shell_hint("`libreoffice --headless --convert-to txt <path>`")}

  # ── Strong: executables & object code ─────────────────────────────────

  defp strong(<<0x7F, "ELF", _::binary>>),
    do:
      {:binary, "an ELF binary (a Linux executable, shared object, or core dump)",
       shell_hint("`file <path>`, `nm -D <path>`, or `strings <path>` for any embedded text")}

  defp strong(<<0xCF, 0xFA, 0xED, 0xFE, _::binary>>), do: mach_o_verdict()
  defp strong(<<0xCE, 0xFA, 0xED, 0xFE, _::binary>>), do: mach_o_verdict()
  defp strong(<<0xFE, 0xED, 0xFA, 0xCF, _::binary>>), do: mach_o_verdict()
  defp strong(<<0xFE, 0xED, 0xFA, 0xCE, _::binary>>), do: mach_o_verdict()

  defp strong(<<0xCA, 0xFE, 0xBA, 0xBE, _::binary>>),
    do:
      {:binary,
       "a Java .class file or a Mach-O universal (fat) binary — both share this signature",
       shell_hint("`javap -c <path>` for Java, or `file <path>` to tell the two apart")}

  defp strong(<<0x00, "asm", _::binary>>),
    do: {:binary, "a WebAssembly module", shell_hint("`wasm2wat <path>` to see its text form")}

  defp strong(<<"FOR1", _::binary-size(4), "BEAM", _::binary>>),
    do:
      {:binary, "a compiled Erlang/Elixir BEAM module",
       "Read the corresponding `.ex`/`.erl` source instead — `file_glob` will find it."}

  # ── Strong: media ─────────────────────────────────────────────────────

  defp strong(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>),
    do: {:binary, "a WAV audio file", shell_hint("`ffprobe <path>`")}

  defp strong(<<"RIFF", _::binary-size(4), "AVI ", _::binary>>),
    do: {:binary, "an AVI video file", shell_hint("`ffprobe <path>`")}

  defp strong(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>),
    do: {:binary, "a Matroska/WebM container (.mkv/.webm)", shell_hint("`ffprobe <path>`")}

  defp strong(<<_::binary-size(4), "ftyp", _::binary>>),
    do:
      {:binary, "an ISO base-media container (.mp4/.m4a/.mov/.heic)",
       shell_hint("`ffprobe <path>`")}

  defp strong(_), do: nil

  # `ustar` lives at offset 257, past every other signature above.
  defp tar(bytes) when byte_size(bytes) >= 262 do
    case binary_part(bytes, 257, 5) do
      "ustar" -> {:binary, "a tar archive", shell_hint("`tar -tf <path>` to list it")}
      _ -> nil
    end
  end

  defp tar(_), do: nil

  # ── Weak tier + text fallback ─────────────────────────────────────────

  # Short ASCII signatures are only trusted once the content has already been
  # judged non-text. Every real file carrying one of these has NUL bytes or
  # invalid UTF-8 within the first few KB, so nothing is lost by demoting them.
  defp weak_or_text(bytes) do
    case text_fallback(bytes) do
      :text -> :text
      binary_verdict -> weak(bytes) || binary_verdict
    end
  end

  defp weak(<<"BM", _::binary>>), do: {:image, "image/bmp", "a BMP image"}

  defp weak(<<"MZ", _::binary>>),
    do:
      {:binary, "a DOS/Windows executable (PE: .exe or .dll)",
       shell_hint("`file <path>`, or `strings <path>` for any embedded text")}

  defp weak(<<"ID3", _::binary>>),
    do: {:binary, "an MP3 audio file (ID3-tagged)", shell_hint("`ffprobe <path>`")}

  defp weak(<<"OggS", _::binary>>),
    do: {:binary, "an Ogg container (audio or video)", shell_hint("`ffprobe <path>`")}

  defp weak(<<"fLaC", _::binary>>),
    do: {:binary, "a FLAC audio file", shell_hint("`ffprobe <path>`")}

  defp weak(<<"PACK", _::binary>>),
    do: {:binary, "a Git packfile", shell_hint("`git verify-pack -v <path>`, or the `git` tool")}

  defp weak(<<"OTTO", _::binary>>),
    do: {:binary, "an OpenType font", shell_hint("`fc-query <path>`")}

  defp weak(<<"wOFF", _::binary>>),
    do: {:binary, "a WOFF web font", shell_hint("`fc-query <path>`")}

  defp weak(<<0x00, 0x01, 0x00, 0x00, 0x00, _::binary>>),
    do: {:binary, "a TrueType font", shell_hint("`fc-query <path>`")}

  defp weak(_), do: nil

  defp text_fallback(""), do: :text

  defp text_fallback(bytes) do
    cond do
      # A NUL byte in the first few KB is the classic "this is not text" tell,
      # and it is what makes a naive read return unusable garbage.
      String.contains?(bytes, <<0>>) ->
        {:binary,
         "unrecognised binary data — no known file signature (first bytes: #{hex_preview(bytes)})",
         shell_hint(
           "`file <path>` to identify it and then the matching tool, or `strings <path>` for any embedded text"
         )}

      valid_utf8_prefix?(bytes) ->
        :text

      true ->
        {:binary,
         "data in an unknown non-UTF-8 encoding — no known file signature (first bytes: #{hex_preview(bytes)})",
         "Use `shell_execute` with `file -I <path>` to detect the encoding, then " <>
           "`iconv -f <that encoding> -t UTF-8 <path>` to convert it before reading."}
    end
  end

  # The sniff window can slice a multi-byte codepoint in half, which would make
  # a perfectly good UTF-8 file look invalid. Allow up to 3 trailing bytes to be
  # discarded before deciding the prefix is not text.
  defp valid_utf8_prefix?(bytes) do
    Enum.any?(0..3, fn drop ->
      size = byte_size(bytes) - drop
      size >= 0 and String.valid?(binary_part(bytes, 0, size))
    end)
  end

  @doc """
  Render the leading bytes of `binary` as lowercase hex, for embedding in a message.

  Public because the refusal text is the feature: tests assert on it.
  """
  @spec hex_preview(binary(), pos_integer()) :: String.t()
  def hex_preview(bytes, count \\ 8) do
    bytes
    |> binary_part(0, min(count, byte_size(bytes)))
    |> :binary.bin_to_list()
    |> Enum.map_join(" ", fn b ->
      b |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    end)
  end

  defp zip_verdict do
    {:binary, "a ZIP archive (also how .jar/.docx/.xlsx/.odt/.epub are stored)",
     shell_hint("`unzip -l <path>` to list entries, then `unzip -p <path> <entry>` to read one")}
  end

  defp mach_o_verdict do
    {:binary, "a Mach-O binary (a macOS executable or dylib)",
     shell_hint("`file <path>`, `otool -L <path>`, or `strings <path>` for any embedded text")}
  end

  defp shell_hint(command), do: "Use `shell_execute` with #{command} instead."

  defp iconv_hint(encoding) do
    "Use `shell_execute` with `iconv -f #{encoding} -t UTF-8 <path>` to convert it to UTF-8, " <>
      "then read the converted file."
  end
end
