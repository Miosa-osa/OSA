defmodule OptimalSystemAgent.Providers.ThinkStreamParser do
  @moduledoc """
  Streaming splitter for inline reasoning tags emitted inside the *normal
  content channel*.

  Some models (notably GLM / `glm-5.2`) do NOT expose reasoning on a separate
  `reasoning_content` field. Instead they inline it in the assistant content as
  `<think>…</think>` (and the common variants `<thinking>`, `<thought>`,
  `<reason>`, `<reasoning>`, `<scratchpad>`, `<analysis>`). If the raw content
  stream is shown as-is, the reasoning text AND the literal tags leak into the
  visible assistant message.

  Entry into think-mode is boundary-aware: an opening tag immediately followed
  by inline whitespace is treated as a tag *mentioned* in prose (e.g. "wrap
  steps in `<think>` tags") and kept literally, rather than swallowing the rest
  of the stream. A tag followed by content or a line break is a real reasoning
  block and is scrubbed.

  This parser is a tiny character state machine that consumes streamed content
  chunks and separates them into two channels:

    * `visible`  — safe to render as the assistant answer (tags + reasoning removed)
    * `thinking` — the inner reasoning text, routed to the collapsible thinking box

  It is streaming-safe: a tag may be split across chunks (`"<thi"` in one chunk,
  `"nk>"` in the next). When the tail of a chunk could be the start of a tag, the
  parser holds it in `pending` rather than emitting it, so a partial `"<think"`
  is never shown and then rewritten. Call `flush/1` at end-of-stream to drain any
  held tail.

  Native reasoning channels (Anthropic thinking blocks, DeepSeek
  `reasoning_content`) are handled elsewhere and are untouched by this parser —
  it only ever inspects the content channel.
  """

  # Opening / closing tags treated as inline reasoning. The set is deliberately
  # broad: CoT leaks are "not just GLM" - other models emit <thought>,
  # <scratchpad> and <analysis> (and uppercase REASONING) just as readily.
  # None is a prefix of another, so order is irrelevant to matching.
  @open_tags [
    "<think>",
    "<thinking>",
    "<thought>",
    "<reason>",
    "<reasoning>",
    "<scratchpad>",
    "<analysis>"
  ]
  @close_tags [
    "</think>",
    "</thinking>",
    "</thought>",
    "</reason>",
    "</reasoning>",
    "</scratchpad>",
    "</analysis>"
  ]

  defstruct in_think: false, pending: ""

  @type t :: %__MODULE__{in_think: boolean(), pending: String.t()}

  @doc "A fresh parser state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed a content chunk. Returns `{visible, thinking, new_state}`.

  Either string may be empty (a chunk fully inside a think block yields
  `visible == ""`). Carry `new_state` into the next `feed/2` call.
  """
  @spec feed(t(), String.t()) :: {String.t(), String.t(), t()}
  def feed(%__MODULE__{in_think: in_think, pending: pending}, chunk)
      when is_binary(chunk) do
    {vis, think, in_think2, hold} = scan(pending <> chunk, in_think, "", "")
    {vis, think, %__MODULE__{in_think: in_think2, pending: hold}}
  end

  @doc """
  Drain any held tail at end-of-stream. Returns `{visible, thinking, new_state}`.

  A non-empty `pending` is either an incomplete tag fragment (a run starting
  with `<` that is a strict prefix of a reasoning tag) or a complete opening tag
  held back one char for the boundary check (`scan/4` only holds these two
  shapes; ordinary text is appended to a channel immediately, never held). If
  the stream ends still holding one, no content ever followed it: the fragment
  never completed, and a held opening tag has nothing after it to keep - so drop
  it rather than leak a literal partial or bare tag into the visible answer (or
  the thinking box). Both channels come back empty.
  """
  @spec flush(t()) :: {String.t(), String.t(), t()}
  def flush(%__MODULE__{}), do: {"", "", %__MODULE__{}}

  # ── internal scan ────────────────────────────────────────────────────────

  # scan(buffer, in_think?, visible_acc, thinking_acc)
  #   -> {visible, thinking, in_think?, pending}
  defp scan("", in_think, vis, think), do: {vis, think, in_think, ""}

  # Outside a think block: look for the next opening tag.
  defp scan(buf, false, vis, think) do
    case :binary.match(buf, "<") do
      :nomatch ->
        {vis <> buf, think, false, ""}

      {0, _} ->
        case classify(buf, @open_tags) do
          {:match, len} ->
            <<tag::binary-size(len), rest::binary>> = buf

            cond do
              # Opening tag sits at the very end of the buffer: we need one more
              # character to tell a real reasoning block from a bare prose
              # mention. Hold the whole tag and decide on the next chunk.
              rest == "" ->
                {vis, think, false, buf}

              # Boundary-aware: a tag that sits MID-LINE and is followed by inline
              # whitespace ("the <think> tag") is a prose mention - keep it
              # literally in the visible answer. A tag at LINE-START opens a real
              # reasoning block even when a space follows it ("<think> reasoning"),
              # so it must NOT be mistaken for prose (that leaked the whole block).
              not at_line_start?(vis) and prose_mention?(rest) ->
                scan(rest, false, vis <> tag, think)

              # Content or a line break follows: a real inline reasoning block.
              true ->
                scan(rest, true, vis, think)
            end

          :partial ->
            # Whole remaining buffer could be the start of an opening tag — hold it.
            {vis, think, false, buf}

          :none ->
            # Defensive: a stray CLOSING reasoning tag with no matching open (e.g.
            # the opening tag was consumed upstream, or the stream started
            # mid-reasoning) must never leak literally. Strip it and stay outside.
            case classify(buf, @close_tags) do
              {:match, len} ->
                <<_::binary-size(len), rest::binary>> = buf
                scan(rest, false, vis, think)

              :partial ->
                {vis, think, false, buf}

              :none ->
                <<"<", rest::binary>> = buf
                scan(rest, false, vis <> "<", think)
            end
        end

      {i, _} ->
        <<before::binary-size(i), rest::binary>> = buf
        scan(rest, false, vis <> before, think)
    end
  end

  # Inside a think block: everything is reasoning until we see a closing tag.
  defp scan(buf, true, vis, think) do
    case :binary.match(buf, "<") do
      :nomatch ->
        {vis, think <> buf, true, ""}

      {0, _} ->
        case classify(buf, @close_tags) do
          {:match, len} ->
            <<_::binary-size(len), rest::binary>> = buf
            scan(rest, false, vis, think)

          :partial ->
            {vis, think, true, buf}

          :none ->
            <<"<", rest::binary>> = buf
            scan(rest, true, vis, think <> "<")
        end

      {i, _} ->
        <<before::binary-size(i), rest::binary>> = buf
        scan(rest, true, vis, think <> before)
    end
  end

  # Given a buffer that starts with "<", decide whether it is a full tag,
  # a strict prefix of a tag (incomplete — hold for more), or neither.
  #
  # Tag matching is CASE-INSENSITIVE: models emit `<THINK>` / `<Thinking>` as
  # readily as the lowercase forms, and the persisted sanitizer already strips
  # them case-insensitively — so a case-sensitive parser here leaked `<THINK>`
  # reasoning into the visible answer. The tags are pure ASCII, so comparing a
  # downcased copy preserves byte lengths: `byte_size(tag)` is still exactly the
  # number of bytes to consume from the ORIGINAL `buf`.
  defp classify(buf, tags) do
    down = String.downcase(buf)

    cond do
      tag = Enum.find(tags, &String.starts_with?(down, &1)) ->
        {:match, byte_size(tag)}

      Enum.any?(tags, &String.starts_with?(&1, down)) ->
        :partial

      true ->
        :none
    end
  end

  # Whitespace immediately after an opening tag marks it as a tag *mentioned* in
  # prose (a standalone token, like "<think> tags") rather than a real reasoning
  # block whose content starts right after the tag. Only inline whitespace
  # (space / tab) counts: a line break after the tag is normal model formatting
  # for a genuine reasoning block, so it still enters think-mode.
  defp prose_mention?(<<c, _::binary>>) when c in [?\s, ?\t], do: true
  defp prose_mention?(_), do: false

  # True when everything since the last newline in the visible text so far is
  # whitespace - i.e. the opening tag is the first non-blank thing on its line
  # and therefore opens a real reasoning block, not a mid-sentence mention.
  defp at_line_start?(vis) do
    vis |> :binary.split("\n", [:global]) |> List.last() |> String.trim() == ""
  end
end
