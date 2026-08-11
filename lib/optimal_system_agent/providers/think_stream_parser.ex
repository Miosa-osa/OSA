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

  A partial tag that never completed is emitted to whichever channel we were in
  (visible if outside a think block, thinking if inside) so no characters are
  silently dropped from the live display.
  """
  @spec flush(t()) :: {String.t(), String.t(), t()}
  def flush(%__MODULE__{pending: ""} = state), do: {"", "", state}

  def flush(%__MODULE__{in_think: true, pending: pending}),
    do: {"", pending, %__MODULE__{}}

  def flush(%__MODULE__{in_think: false, pending: pending}),
    do: {pending, "", %__MODULE__{}}

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
  defp classify(buf, tags) do
    cond do
      tag = Enum.find(tags, &String.starts_with?(buf, &1)) ->
        {:match, byte_size(tag)}

      Enum.any?(tags, &String.starts_with?(&1, buf)) ->
        :partial

      true ->
        :none
    end
  end
end
