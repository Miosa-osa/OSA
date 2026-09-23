defmodule OptimalSystemAgent.Providers.HistorySanitizer do
  @moduledoc """
  Provider-agnostic transcript repair, applied before every provider request.

  Three shapes of self-inflicted history corruption produce a request-shape
  `400` that repeats on EVERY subsequent turn once persisted, because nothing
  ever fixes the shape that triggered it:

    1. A `tool` message (`tool_result`) whose `tool_call_id` answers no
       `tool_use` anywhere in the history — the provider rejects an
       "unexpected tool_use_id" ("no such tool_use block was found"). DROPPED.
    2. An assistant `tool_calls` entry with no following `tool` result — the
       provider rejects the missing pairing ("tool_use ids were found
       without..."). FILLED with a synthetic placeholder result.
    3. A message whose entire content collapses to nothing (an empty string,
       or a content-block list whose only blocks are blank text) — the
       provider rejects an empty content field/block. The degenerate message
       is DROPPED entirely (nothing informative was ever in it); a block list
       that still has other content (an image, a non-blank text run) only has
       its blank text blocks removed, and adjacent plain-text blocks (no
       `cache_control` marker) are MERGED so a fragmented accumulation does
       not linger as several near-empty blocks.

  ## What this module never touches

  * **Order.** Every operation is a filter/insert-in-place; nothing is
    reordered. Anthropic requires a `tool_result` in the message immediately
    following its `tool_use` — see `fill_missing_tool_results/2`, which
    inserts there, never at the tail.
  * **`:thinking_blocks`.** A message carrying signed thinking blocks
    (`Providers.Anthropic.format_messages/1`) must be replayed to the
    provider byte-for-byte or the interleaved-thinking round-trip 400s and the
    thinking-block prompt cache breaks. This module only inspects `:role`,
    `:tool_calls`, `:tool_call_id` and `:content` — a message with a
    `:thinking_blocks` key is left completely alone by the empty-text pass,
    and is never a candidate for the tool-result passes (those only ever look
    at `role: "tool"` / `tool_calls` entries).

  ## Two call sites

  * **Pre-flight** (`sanitize/2`) — run on every outbound request
    (`Loop.LLMClient.llm_chat/3`, `llm_chat_stream/3`) so corruption never
    reaches the wire in the first place.
  * **One-shot repair-and-retry** — when a provider returns a request-shape
    `400` anyway (a corruption pattern this module does not yet recognise, or
    one introduced between the pre-flight pass and the request), the SAME
    functions are run again and the request is retried exactly once if — and
    only if — they actually changed something. No change means nothing here
    can help, so the caller must not loop.
  * **Crash restore** (`fill_missing_tool_results/2` called directly, with
    restart-specific wording) — `Loop.init/1` fills orphaned `tool_use`
    entries with an "interrupted by a restart, outcome unknown" placeholder
    BEFORE the first post-restore request, so the model reasons about
    uncertain side effects instead of the generic "no result recorded" text
    `sanitize/2`'s pre-flight pass would otherwise supply.
  """

  @type message :: map()

  @default_orphan_result_text "No result was recorded for this tool call " <>
                                "(the conversation history was repaired before sending)."

  @doc """
  Run every repair pass over `messages`. Returns `{messages, changed?}` so
  callers can log/retry only when a repair actually happened.

  Options:

    * `:orphan_result_text` — placeholder content for a synthetic tool result
      inserted for an orphaned `tool_use` (default: a generic
      "history was repaired" note). Crash-restore callers pass their own
      restart-specific wording via `fill_missing_tool_results/2` directly
      instead of through here — see the moduledoc.
  """
  @spec sanitize([message()], keyword()) :: {[message()], boolean()}
  def sanitize(messages, opts \\ []) when is_list(messages) do
    placeholder = Keyword.get(opts, :orphan_result_text, @default_orphan_result_text)

    {messages, dropped?} = drop_orphaned_tool_results(messages)
    {messages, filled?} = fill_missing_tool_results(messages, placeholder)
    {messages, pruned?} = normalize_empty_text(messages)

    {messages, dropped? or filled? or pruned?}
  end

  @doc """
  Drop every `role: "tool"` message whose `tool_call_id` answers no
  `tool_use` anywhere in `messages`. No provider accepts an orphan
  `tool_result` — keeping it around guarantees the same 400 forever once the
  corrupted shape is persisted.
  """
  @spec drop_orphaned_tool_results([message()]) :: {[message()], boolean()}
  def drop_orphaned_tool_results(messages) do
    tool_use_ids = all_tool_use_ids(messages)

    {reversed, dropped?} =
      Enum.reduce(messages, {[], false}, fn msg, {acc, dropped?} ->
        if msg_role(msg) == "tool" do
          case tool_result_id(msg) do
            nil ->
              {[msg | acc], dropped?}

            id ->
              if MapSet.member?(tool_use_ids, id) do
                {[msg | acc], dropped?}
              else
                {acc, true}
              end
          end
        else
          {[msg | acc], dropped?}
        end
      end)

    {Enum.reverse(reversed), dropped?}
  end

  @doc """
  Give every `tool_use` with no answering `tool` result a synthetic one.

  `placeholder` is either a fixed string (used for every orphan) or a
  1-arity function receiving the tool_call_id, so a caller can name the call
  in its own placeholder text. The synthetic result is inserted IMMEDIATELY
  AFTER the assistant message that owns the `tool_use` — never appended at
  the tail — because Anthropic (and other strict providers) require the
  `tool_result` in the very next message.

  Scans every assistant message, not just the last one: an assistant message
  carrying both text and tool calls can be followed by other messages before
  the turn ends, so a last-message-only scan misses orphans that are not at
  the very end of history.
  """
  @spec fill_missing_tool_results([message()], String.t() | (String.t() -> String.t())) ::
          {[message()], boolean()}
  def fill_missing_tool_results(messages, placeholder) when is_binary(placeholder) do
    fill_missing_tool_results(messages, fn _id -> placeholder end)
  end

  def fill_missing_tool_results(messages, placeholder_fun) when is_function(placeholder_fun, 1) do
    answered = answered_tool_ids(messages)

    {reversed, filled?} =
      Enum.reduce(messages, {[], false}, fn msg, {acc, filled?} ->
        case orphaned_tool_call_ids(msg, answered) do
          [] ->
            {[msg | acc], filled?}

          ids ->
            results =
              Enum.map(ids, fn id ->
                %{role: "tool", tool_call_id: id, content: placeholder_fun.(id)}
              end)

            # `acc` is reversed, so push the results in reverse order so they
            # land, in the original order, immediately after `msg`.
            {Enum.reverse(results) ++ [msg | acc], true}
        end
      end)

    {Enum.reverse(reversed), filled?}
  end

  @doc """
  Drop degenerate (fully empty) messages and blank text blocks, and merge
  adjacent plain-text blocks (no `cache_control` marker) left behind by the
  drop.

  A message is a candidate ONLY when its role is neither `"tool"` (a result's
  content — even an empty one, e.g. a command with no stdout — is legitimate
  and never touched) nor carrying `:thinking_blocks` (must be replayed
  unchanged, see moduledoc), and it carries no `tool_calls` (a tool-calling
  assistant message with blank text is already valid — the `tool_use` blocks
  are its real content).
  """
  @spec normalize_empty_text([message()]) :: {[message()], boolean()}
  def normalize_empty_text(messages) do
    {reversed, changed?} =
      Enum.reduce(messages, {[], false}, fn msg, {acc, changed?} ->
        case normalize_message(msg) do
          :drop -> {acc, true}
          {:keep, ^msg} -> {[msg | acc], changed?}
          {:keep, new_msg} -> {[new_msg | acc], true}
        end
      end)

    {Enum.reverse(reversed), changed?}
  end

  # ── private ────────────────────────────────────────────────────────────

  defp normalize_message(msg) do
    cond do
      msg_role(msg) == "tool" -> {:keep, msg}
      Map.has_key?(msg, :thinking_blocks) or Map.has_key?(msg, "thinking_blocks") -> {:keep, msg}
      has_tool_calls?(msg) -> {:keep, msg}
      true -> normalize_content(msg)
    end
  end

  defp normalize_content(msg) do
    content = Map.get(msg, :content) || Map.get(msg, "content")

    case content do
      content when is_binary(content) ->
        if String.trim(content) == "", do: :drop, else: {:keep, msg}

      content when is_list(content) ->
        case rebuild_block_list(content) do
          [] -> :drop
          blocks -> {:keep, put_content(msg, blocks)}
        end

      nil ->
        :drop

      _other ->
        {:keep, msg}
    end
  end

  defp put_content(msg, value) do
    if Map.has_key?(msg, "content"),
      do: Map.put(msg, "content", value),
      else: Map.put(msg, :content, value)
  end

  # Drop blank text blocks, then merge consecutive plain-text blocks (no
  # cache_control) so a fragmented accumulation collapses to one block.
  # Non-text blocks (images, tool_result passthrough, anything with a
  # cache_control breakpoint) are left exactly where they are, and never
  # merged across.
  defp rebuild_block_list(blocks) do
    blocks
    |> Enum.reject(&blank_text_block?/1)
    |> Enum.reduce([], fn block, acc ->
      case {acc, plain_text_block?(block)} do
        {[{:merge, prev_text} | rest], true} ->
          [{:merge, prev_text <> block_text(block)} | rest]

        {_, true} ->
          [{:merge, block_text(block)} | acc]

        {_, false} ->
          [{:keep, block} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {:merge, text} -> text_block(text)
      {:keep, block} -> block
    end)
  end

  defp blank_text_block?(block) do
    type = block_type(block)
    type in ["text", :text] and blank?(block_text(block))
  end

  defp plain_text_block?(block) do
    type = block_type(block)
    type in ["text", :text] and not has_cache_control?(block)
  end

  defp block_type(block) when is_map(block), do: Map.get(block, "type") || Map.get(block, :type)
  defp block_type(block) when is_binary(block), do: "text"
  defp block_type(_block), do: nil

  defp block_text(block) when is_map(block),
    do: Map.get(block, "text") || Map.get(block, :text) || ""

  defp block_text(block) when is_binary(block), do: block
  defp block_text(_block), do: ""

  defp has_cache_control?(block) when is_map(block),
    do: Map.has_key?(block, "cache_control") or Map.has_key?(block, :cache_control)

  defp has_cache_control?(_block), do: false

  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp blank?(text), do: is_binary(text) and String.trim(text) == ""

  defp has_tool_calls?(msg) do
    case Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") do
      list when is_list(list) and list != [] -> true
      _ -> false
    end
  end

  # Every id that appears as a `tool_use` (an assistant `tool_calls` entry) in
  # `messages`, regardless of whether it was ever answered.
  defp all_tool_use_ids(messages) do
    for msg <- messages,
        msg_role(msg) == "assistant",
        tc <- tool_calls_of(msg),
        id = tool_call_id(tc),
        not is_nil(id),
        into: MapSet.new(),
        do: id
  end

  defp tool_result_id(msg),
    do: Map.get(msg, :tool_call_id) || Map.get(msg, "tool_call_id")

  # Ids of every tool call in `msg` that no `tool` message answers. Tolerates
  # both atom- and string-keyed messages (checkpoint restore decodes to
  # strings) and tool calls missing an id (nothing to answer — skipped).
  defp orphaned_tool_call_ids(msg, answered) do
    case msg_role(msg) do
      "assistant" ->
        msg
        |> tool_calls_of()
        |> Enum.map(&tool_call_id/1)
        |> Enum.reject(&(is_nil(&1) or MapSet.member?(answered, &1)))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp answered_tool_ids(messages) do
    for msg <- messages,
        msg_role(msg) == "tool",
        id = tool_result_id(msg),
        not is_nil(id),
        into: MapSet.new(),
        do: id
  end

  defp msg_role(msg) when is_map(msg), do: Map.get(msg, :role) || Map.get(msg, "role")
  defp msg_role(_msg), do: nil

  defp tool_calls_of(msg) do
    case Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp tool_call_id(tc) when is_map(tc), do: Map.get(tc, :id) || Map.get(tc, "id")
  defp tool_call_id(_tc), do: nil
end
