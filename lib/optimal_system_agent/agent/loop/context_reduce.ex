defmodule OptimalSystemAgent.Agent.Loop.ContextReduce do
  @moduledoc """
  A cheaper tier of context reduction than full compaction.

  `Agent.Loop.ProactiveCompaction` folds old turns into an LLM-written
  summary — real value, real cost (a provider round trip, and it rewrites the
  whole warm zone). Most of a long session's bulk is not that subtle: it is
  tool RESULTS the model already acted on and will never need again verbatim.
  This module removes exactly that, mechanically, with zero LLM calls:

  it replaces the *content* of stale tool-result messages with a one-line
  stub — tool name, a short argument hint, original size, and where the full
  output is stored — while leaving the tool CALL that produced it (the
  assistant message with `tool_calls`) untouched. The model's working memory
  of *what it did* survives; the payload of *what it got back* does not, but
  is never lost either.

  ## What "stale" means

  A tool-result message is a candidate when it is OUTSIDE the most recent
  `:keep_recent_turns` user-delimited turns (never the in-flight turn or the
  handful just before it — mirrors the HOT-zone philosophy in
  `Agent.Compactor` and the tool-pair safety concerns in `ContextCollapse`,
  without depending on either module).

  ## Prompt-cache-aware batching

  Anthropic-style prompt caching (`Providers.PromptCache`) depends on the
  request prefix being byte-identical across turns. Editing ONE old message
  breaks the cached prefix from that point forward — a real cost, paid once.
  Editing a different old message on every subsequent turn would pay that
  cost EVERY turn, which is worse than never clearing anything.

  So this function is a deliberate no-op — returns `messages` byte-for-byte
  unchanged — until at least `:batch_size` stale, not-yet-cleared candidates
  have accumulated, and then clears ALL of them in a single pass. Between
  batches, calling this repeatedly costs nothing (same input, same output,
  cache stays warm). Once a message is stubbed it never changes again
  (`already_cleared?/1` is a hard skip), so the boundary only ever moves
  forward in discrete jumps instead of drifting by one message every turn.

  ## Nothing is lost

  Before a tool result's content is replaced, the full text is guaranteed
  recoverable:

    * if the content already carries an on-disk reference (from
      `ToolResultStorage.apply_budget/4`, the tool-executor's
      `spill_or_truncate/3`, or `ContextCollapse`'s oversized-message trim —
      all three write into the same `tool-results` directory), that EXISTING
      path is reused and nothing is written twice;
    * otherwise the full content is persisted via
      `ToolResultStorage.persist/4`, the same storage this module's siblings
      already use, so `expand_output` (or `file_read`) can retrieve it later.

  ## For the homeostat

  `clear_stale_tool_results/2` is the one function the pain-channel/homeostat
  needs: pure over its input list plus options, side effect confined to
  writing already-necessary backup files, and safe to call every turn — most
  calls are the fast no-op path described above.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage
  alias OptimalSystemAgent.Utils.Text

  @default_keep_recent_turns 6
  @default_batch_size 5
  @default_min_bytes 300

  @stub_marker "[Tool result cleared —"

  # Reference patterns already in use across the codebase for "the full
  # content lives at this path" notes, so a message that was ALREADY offloaded
  # (by `ToolResultStorage.apply_budget/4`, `ToolExecutor.spill_or_truncate/3`,
  # or `ContextCollapse.trim_oversized_latest_message/3`) is recognized and its
  # existing file is reused instead of a duplicate write.
  @existing_ref_patterns [
    ~r/Full output written to (\S+) /,
    ~r/saved at (\S+)\./,
    ~r/saved to (\S+\.txt)/
  ]

  @type stats :: %{
          cleared: non_neg_integer(),
          bytes_saved: non_neg_integer(),
          pending: non_neg_integer()
        }

  @doc """
  Replace stale tool-result content with one-line stubs, in prompt-cache-safe
  batches.

  ## Options

    * `:keep_recent_turns` — user-delimited turns (from the end) that are
      NEVER touched, regardless of size. Default #{@default_keep_recent_turns}.
    * `:batch_size` — minimum number of stale, not-yet-cleared candidates
      required before ANY clearing happens. Default #{@default_batch_size}.
    * `:min_bytes` — tool results smaller than this are left alone; there is
      nothing worth reclaiming. Default #{@default_min_bytes}.
    * `:session_id` — threaded into `ToolResultStorage.persist/4` so offloaded
      files are cleaned up with the rest of the session's tool-results on
      `ToolResultStorage.cleanup/1`.

  Returns `{messages, stats}` where `stats` is
  `%{cleared: n, bytes_saved: n, pending: n}` — `pending` is how many stale
  candidates exist but were left alone because the batch has not filled yet.
  """
  @spec clear_stale_tool_results([map()], keyword()) :: {[map()], stats()}
  def clear_stale_tool_results(messages, opts \\ [])

  def clear_stale_tool_results(messages, opts) when is_list(messages) do
    keep_turns = Keyword.get(opts, :keep_recent_turns, @default_keep_recent_turns)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    min_bytes = Keyword.get(opts, :min_bytes, @default_min_bytes)
    session_id = Keyword.get(opts, :session_id)

    hot_start = hot_boundary(messages, keep_turns)
    candidates = find_candidates(messages, hot_start, min_bytes)

    if candidates == [] or length(candidates) < batch_size do
      {messages, %{cleared: 0, bytes_saved: 0, pending: length(candidates)}}
    else
      clear_all(messages, candidates, session_id)
    end
  rescue
    e ->
      Logger.warning("[context_reduce] clear_stale_tool_results failed: #{Exception.message(e)}")
      {messages, %{cleared: 0, bytes_saved: 0, pending: 0}}
  end

  def clear_stale_tool_results(messages, _opts),
    do: {messages, %{cleared: 0, bytes_saved: 0, pending: 0}}

  # ── Hot boundary — turn-aware, self-contained (no dependency on Compactor) ──

  defp hot_boundary(messages, keep_turns) do
    starts =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _i} -> real_user_turn_start?(msg) end)
      |> Enum.map(fn {_msg, i} -> i end)

    case Enum.take(starts, -keep_turns) do
      [first | _] -> first
      [] -> length(messages)
    end
  end

  defp real_user_turn_start?(msg) do
    role = Map.get(msg, :role) || Map.get(msg, "role")
    scaffold? = (Map.get(msg, :scaffold) || Map.get(msg, "scaffold")) == true
    role == "user" and not scaffold?
  end

  # ── Candidate selection ──────────────────────────────────────────────────

  defp find_candidates(messages, hot_start, min_bytes) do
    messages
    |> Enum.with_index()
    |> Enum.filter(fn {msg, idx} ->
      idx < hot_start and tool_result?(msg) and not already_cleared?(msg) and
        big_enough?(msg, min_bytes)
    end)
    |> Enum.map(fn {_msg, idx} -> idx end)
  end

  defp tool_result?(msg), do: (Map.get(msg, :role) || Map.get(msg, "role")) == "tool"

  defp already_cleared?(msg) do
    case content_of(msg) do
      text when is_binary(text) -> String.starts_with?(text, @stub_marker)
      _ -> false
    end
  end

  # Only ever touches plain-text content. Block-shaped content (an image tool
  # result) is left alone — stubbing it would discard structured data this
  # module has no way to reconstruct or re-offload.
  defp big_enough?(msg, min_bytes) do
    case content_of(msg) do
      text when is_binary(text) -> byte_size(text) >= min_bytes
      _ -> false
    end
  end

  # ── Clearing ─────────────────────────────────────────────────────────────

  defp clear_all(messages, candidate_indices, session_id) do
    index_set = MapSet.new(candidate_indices)

    {new_messages, total_saved} =
      messages
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {msg, idx}, acc ->
        if MapSet.member?(index_set, idx) do
          {stubbed, saved} = clear_one(messages, msg, idx, session_id)
          {stubbed, acc + saved}
        else
          {msg, acc}
        end
      end)

    {new_messages, %{cleared: length(candidate_indices), bytes_saved: total_saved, pending: 0}}
  end

  defp clear_one(messages, msg, idx, session_id) do
    text = content_of(msg)
    orig_bytes = byte_size(text)

    tool_name = Map.get(msg, :name) || Map.get(msg, "name") || "tool"
    tool_call_id = Map.get(msg, :tool_call_id) || Map.get(msg, "tool_call_id")

    location = existing_reference(text) || persist(text, tool_name, tool_call_id, session_id)
    arg_hint = arg_hint_for(messages, idx, tool_call_id)

    stub = build_stub(tool_name, arg_hint, orig_bytes, location)

    {put_content(msg, stub), max(orig_bytes - byte_size(stub), 0)}
  end

  defp existing_reference(text) do
    Enum.find_value(@existing_ref_patterns, fn re ->
      case Regex.run(re, text) do
        [_, path] -> path
        _ -> nil
      end
    end)
  end

  defp persist(text, tool_name, tool_call_id, session_id) do
    case ToolResultStorage.persist(text, tool_name, tool_call_id, session_id) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  # A short argument hint from the assistant tool_call message that produced
  # this result — searched backward from `idx` so the stub still says roughly
  # WHAT was asked for, not just that something was.
  defp arg_hint_for(_messages, _idx, nil), do: nil

  defp arg_hint_for(messages, idx, tool_call_id) do
    messages
    |> Enum.take(idx)
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      calls = Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls")

      if is_list(calls) do
        Enum.find_value(calls, fn call ->
          id = Map.get(call, :id) || Map.get(call, "id")

          if id == tool_call_id do
            Map.get(call, :arguments) || Map.get(call, "arguments")
          end
        end)
      end
    end)
    |> format_arg_hint()
  end

  defp format_arg_hint(nil), do: nil
  defp format_arg_hint(""), do: nil
  defp format_arg_hint(%{} = args) when map_size(args) == 0, do: nil

  defp format_arg_hint(args) do
    args |> Text.safe_to_string() |> String.slice(0, 80)
  end

  defp build_stub(tool_name, arg_hint, orig_bytes, location) do
    args_part = if arg_hint, do: " args=#{arg_hint}", else: ""
    where = location || "not recoverable (persist failed)"

    "#{@stub_marker} #{tool_name}#{args_part}, #{orig_bytes} bytes. " <>
      "Full output: #{where}. Use expand_output (or file_read) if you need it again.]"
  end

  # ── Content access (atom OR string keys, per message shape in this codebase) ──

  # Deliberately the RAW value, not `Text.content_text/1` — that helper joins
  # block-shaped (e.g. image) content down to its text parts, which would make
  # a list look exactly like a plain-text result and defeat the block-content
  # skip in `big_enough?/2`. Every caller here only ever proceeds past a
  # `is_binary/1` guard, so nothing downstream needs the joined form.
  defp content_of(msg), do: Map.get(msg, :content) || Map.get(msg, "content")

  defp put_content(%{content: _} = msg, c), do: %{msg | content: c}
  defp put_content(%{"content" => _} = msg, c), do: Map.put(msg, "content", c)
  defp put_content(msg, c), do: Map.put(msg, :content, c)
end
