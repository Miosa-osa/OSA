defmodule OptimalSystemAgent.Providers.ThinkStreamParser do
  @moduledoc """
  Streaming splitter for inline reasoning tags emitted inside the *normal
  content channel*.

  Some models (notably GLM / `glm-5.2`) do NOT expose reasoning on a separate
  `reasoning_content` field. Instead they inline it in the assistant content as
  `<think>…</think>` (and the common variants `<thinking>`, `<reason>`,
  `<reasoning>`). If the raw content stream is shown as-is, the reasoning text
  AND the literal tags leak into the visible assistant message.

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

  # Opening / closing tags treated as inline reasoning. Longest first is not
  # required (none is a prefix of another) but order is irrelevant to matching.
  @open_tags ["<think>", "<thinking>", "<reason>", "<reasoning>"]
  @close_tags ["</think>", "</thinking>", "</reason>", "</reasoning>"]

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

  A non-empty `pending` is ALWAYS an incomplete tag fragment: `scan/4` only ever
  holds a run that starts with `<` and is a strict prefix of a reasoning tag
  (ordinary text is appended to a channel immediately, never held). If the stream
  ends still holding one, the tag never completed, so the fragment is a dangling
  `<` / `<th` with no meaning — drop it rather than leak the literal partial tag
  into the visible answer (or the thinking box). Both channels come back empty.
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
            <<_::binary-size(len), rest::binary>> = buf
            scan(rest, true, vis, think)

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
end
