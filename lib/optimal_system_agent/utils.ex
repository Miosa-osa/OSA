defmodule OptimalSystemAgent.Utils do
  @moduledoc """
  Shared utility functions used across the OptimalSystemAgent codebase.

  Sub-modules:
  - `OptimalSystemAgent.Utils.Tokens` — heuristic token estimation
  - `OptimalSystemAgent.Utils.Text`   — string manipulation helpers
  - `OptimalSystemAgent.Utils.ID`     — unique ID generation
  """
end

defmodule OptimalSystemAgent.Utils.Tokens do
  @moduledoc """
  Token estimation utilities.

  The heuristic formula (words * 1.3 + punctuation * 0.5) is an empirically
  derived approximation of BPE token counts for English text. It is used as
  a fallback when the Go tokenizer or Rust NIF is unavailable.

  The word heuristic alone is **whitespace-blind**: it assumes text is split by
  spaces, so any payload without them — minified JS/CSS, a single-line JSON
  blob, base64, a long hex digest — collapses to a handful of "words" and is
  under-estimated by one to two orders of magnitude. That is precisely the
  payload shape that blows a context window, and the estimate is consumed by
  the compaction decision, so under-counting there means compaction fails to
  fire exactly when it is needed.

  A byte-length floor of `bytes / 4` (the conventional BPE rule of thumb) is
  therefore applied, and the result is `max(heuristic, floor)`: prose keeps the
  better word-based estimate, whitespace-poor payloads get a realistic one.
  """

  # Conventional BPE approximation: ~4 bytes per token.
  @bytes_per_token 4

  @doc """
  Heuristic token count: `max(words * 1.3 + punctuation * 0.5, bytes / 4)`.

  The byte-length term is a floor, not a replacement — it only wins for
  whitespace-poor input (minified code, base64, single-line JSON), where the
  word heuristic is 20-50x low.

  Returns 0 for non-binary inputs.
  """
  @spec estimate(String.t() | any()) :: non_neg_integer()
  def estimate(text) when is_binary(text) do
    words = text |> String.split(~r/\s+/, trim: true) |> length()
    punctuation = Regex.scan(~r/[^\w\s]/, text) |> length()
    heuristic = round(words * 1.3 + punctuation * 0.5)

    max(heuristic, byte_floor(text))
  end

  def estimate(_), do: 0

  @doc """
  Lower bound on the token count of `text`, from its byte length alone.

  Rounds up, so any non-empty string costs at least one token.
  """
  @spec byte_floor(String.t()) :: non_neg_integer()
  def byte_floor(text) when is_binary(text) do
    div(byte_size(text) + @bytes_per_token - 1, @bytes_per_token)
  end
end

defmodule OptimalSystemAgent.Utils.Text do
  @moduledoc """
  String manipulation helpers used across the codebase.
  """

  @doc """
  Truncates `str` to at most `max_len` characters (Unicode-aware).

  If the string exceeds `max_len`, it is sliced to `max_len - 1` characters
  and an ellipsis character is appended. Returns `""` for non-binary inputs.
  """
  @spec truncate(String.t() | any(), non_neg_integer()) :: String.t()
  def truncate(str, max_len) when is_binary(str) do
    if String.length(str) <= max_len do
      str
    else
      String.slice(str, 0, max_len - 1) <> "…"
    end
  end

  def truncate(_, _), do: ""

  @doc """
  Byte-bounded HEAD of `bin`: at most `max_bytes` bytes, cut back to a UTF-8
  character boundary.

  `binary_part/3` and friends cut at an arbitrary byte offset, which lands
  mid-sequence on most multibyte content and yields invalid UTF-8. Anything
  built from the result and handed to `Jason.encode_to_iodata!/1` — every
  provider request body — then RAISES, so an unguarded byte cut on the way to
  the model is a crash, not a cosmetic defect.

  `String.slice/3` is not a substitute: it counts GRAPHEMES, so asking it for
  "51200" against CJK yields ~150KB and against 4-byte emoji ~200KB.

  The result is always valid UTF-8: the boundary cut handles the common case
  (a clean binary sliced mid-character), and any remaining invalid bytes —
  from a source that was already malformed — are replaced with U+FFFD rather
  than dropped, so length is preserved and nothing is silently lost.
  """
  @spec utf8_head(binary(), non_neg_integer()) :: binary()
  def utf8_head(bin, max_bytes)
      when is_binary(bin) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(bin) <= max_bytes do
      scrub_utf8(bin)
    else
      bin
      |> binary_part(0, max_bytes)
      |> drop_partial_trailing()
      |> scrub_utf8()
    end
  end

  @doc """
  Byte-bounded TAIL of `bin`: at most `max_bytes` bytes, advanced FORWARD to a
  UTF-8 character boundary.

  The tail is the dangerous half of a head+tail split — a cut at
  `byte_size - max_bytes` starts mid-sequence on almost any multibyte content,
  whereas a head cut only misbehaves when the boundary happens to land inside
  the final character. Same validity guarantee as `utf8_head/2`.
  """
  @spec utf8_tail(binary(), non_neg_integer()) :: binary()
  def utf8_tail(bin, max_bytes)
      when is_binary(bin) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(bin) <= max_bytes do
      scrub_utf8(bin)
    else
      bin
      |> binary_part(byte_size(bin) - max_bytes, max_bytes)
      |> drop_partial_leading()
      |> scrub_utf8()
    end
  end

  @doc """
  Coerce `bin` to valid UTF-8, replacing each undecodable byte with U+FFFD.

  Replacement rather than truncation is deliberate: these binaries are logs,
  tool output and crash-recovery records, where silently dropping the tail
  after the first bad byte loses far more than it protects.
  """
  @spec scrub_utf8(binary()) :: binary()
  def scrub_utf8(bin) when is_binary(bin) do
    if String.valid?(bin), do: bin, else: IO.iodata_to_binary(do_scrub(bin, []))
  end

  defp do_scrub(<<>>, acc), do: Enum.reverse(acc)
  defp do_scrub(<<c::utf8, rest::binary>>, acc), do: do_scrub(rest, [<<c::utf8>> | acc])
  defp do_scrub(<<_bad, rest::binary>>, acc), do: do_scrub(rest, [<<0xFFFD::utf8>> | acc])

  # Drop a trailing UTF-8 sequence that the byte cut left incomplete. A UTF-8
  # character is at most 4 bytes, so at most 3 bytes are ever removed.
  defp drop_partial_trailing(bin) do
    case incomplete_tail_len(bin, 0) do
      0 -> bin
      n -> binary_part(bin, 0, byte_size(bin) - n)
    end
  end

  defp incomplete_tail_len(bin, seen) when seen < 4 do
    size = byte_size(bin)

    if size - seen <= 0 do
      seen
    else
      case :binary.at(bin, size - seen - 1) do
        # ASCII: whatever we walked past was stray, not an incomplete sequence.
        b when b < 0x80 -> seen
        # Continuation byte — keep walking back toward the lead byte.
        b when b < 0xC0 -> incomplete_tail_len(bin, seen + 1)
        # Lead byte: incomplete only if the sequence it opens does not fit.
        b -> if seen + 1 < utf8_seq_len(b), do: seen + 1, else: 0
      end
    end
  end

  defp incomplete_tail_len(_bin, seen), do: seen

  defp utf8_seq_len(b) when b < 0xE0, do: 2
  defp utf8_seq_len(b) when b < 0xF0, do: 3
  defp utf8_seq_len(_b), do: 4

  # Drop leading continuation bytes orphaned by a tail cut (at most 3 for a
  # well-formed source; a pathological all-continuation input degrades to "").
  defp drop_partial_leading(<<b, rest::binary>>) when b >= 0x80 and b < 0xC0,
    do: drop_partial_leading(rest)

  defp drop_partial_leading(bin), do: bin

  @doc """
  Strips leading and trailing Markdown code fences from `content`.

  Handles optional language tags (e.g. ` ```json `).
  """
  @spec strip_markdown_fences(String.t() | any()) :: String.t()
  def strip_markdown_fences(content) when is_binary(content) do
    content
    |> String.replace(~r/^```(?:json)?\s*\n?/, "")
    |> String.replace(~r/\n?\s*```\s*$/, "")
  end

  def strip_markdown_fences(content), do: content

  @doc """
  Strips model reasoning/thinking blocks from raw LLM output.

  Handles `<think>`, `<thinking>`, `<reason>`, `<reasoning>`,
  `<|start|>...<|end|>` reasoning tags emitted by GLM, DeepSeek, Qwen, and
  other reasoning models that inline their reasoning in the content channel.

  Both closed blocks and an UNCLOSED leading reasoning tag (a `<think>` that
  never closes — e.g. a truncated stream) are stripped, so the persisted
  transcript is always clean. Matching is case-insensitive.
  """
  @spec strip_thinking_tokens(String.t() | nil | any()) :: String.t()
  def strip_thinking_tokens(nil), do: ""

  def strip_thinking_tokens(content) when is_binary(content) do
    content
    |> String.replace(~r/<think>[\s\S]*?<\/think>/mi, "")
    |> String.replace(~r/<thinking>[\s\S]*?<\/thinking>/mi, "")
    |> String.replace(~r/<reason>[\s\S]*?<\/reason>/mi, "")
    |> String.replace(~r/<reasoning>[\s\S]*?<\/reasoning>/mi, "")
    |> String.replace(~r/<\|start\|>[\s\S]*?<\|end\|>/m, "")
    # Unclosed leading reasoning tag: strip from the opening tag to end-of-string.
    |> String.replace(~r/<(?:think|thinking|reason|reasoning)>[\s\S]*$/i, "")
    |> String.trim()
  end

  def strip_thinking_tokens(other), do: other

  @doc """
  Converts any value to a string safely.

  - `nil`     → `""`
  - binary    → as-is
  - atom      → `Atom.to_string/1`
  - map/list  → `Jason.encode!/1`
  - other     → `inspect/1`
  """
  @spec safe_to_string(any()) :: String.t()
  def safe_to_string(nil), do: ""
  def safe_to_string(val) when is_binary(val), do: val
  def safe_to_string(val) when is_atom(val), do: Atom.to_string(val)
  def safe_to_string(val) when is_map(val), do: Jason.encode!(val)
  def safe_to_string(val) when is_list(val), do: Jason.encode!(val)
  def safe_to_string(val), do: inspect(val)

  @doc """
  The human-readable TEXT of a message's `content`, which may be a plain string
  OR a list of typed content blocks.

  A message gains block-shaped content the moment an image is attached
  (`[%{type: "text", text: ..}, %{type: "image", source: %{data: ..}}]`), and
  several message scanners — scaffold-marker detection, file-hint extraction —
  only ever want the prose. They used `to_string(content)`, which raises
  `ArgumentError: cannot convert the given list to a string` on a block list, so
  attaching an image crashed the turn. This joins the `text` parts (dropping
  image and other non-text blocks) and never raises.

  - binary            → as-is
  - list of blocks    → the `text`/`"text"` parts joined with `"\\n\\n"`
  - nil               → `""`
  - anything else      → `safe_to_string/1`
  """
  @spec content_text(any()) :: String.t()
  def content_text(content) when is_binary(content), do: content
  def content_text(nil), do: ""

  def content_text(content) when is_list(content) do
    content
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def content_text(content), do: safe_to_string(content)

  defp block_text(block) when is_binary(block), do: block
  defp block_text(%{text: t}) when is_binary(t), do: t
  defp block_text(%{"text" => t}) when is_binary(t), do: t
  defp block_text(_), do: ""

  @doc """
  Returns the current UTC time as an ISO 8601 string.
  """
  @spec now_iso() :: String.t()
  def now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

defmodule OptimalSystemAgent.Utils.ID do
  @moduledoc """
  Unique ID generation using cryptographically strong random bytes.
  """

  @doc """
  Generates a random 16-character hex ID, optionally prefixed.

      iex> OptimalSystemAgent.Utils.ID.generate()
      "a3f2c1d4e5b6a7c8"

      iex> OptimalSystemAgent.Utils.ID.generate("task")
      "task_a3f2c1d4e5b6a7c8"
  """
  @spec generate(String.t() | nil) :: String.t()
  def generate(prefix \\ nil) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    if prefix, do: "#{prefix}_#{id}", else: id
  end
end
