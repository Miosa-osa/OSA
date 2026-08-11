defmodule OptimalSystemAgent.Memory.Flush do
  @moduledoc """
  Pre-compaction memory flush — turn hard-won working knowledge into durable
  memory BEFORE compaction summarizes it away.

  ## The problem this solves

  `Agent.Loop.ProactiveCompaction` folds older turns into a summary once usage
  crosses `CompactionThresholds.compact_at/1`. The summary is high-recall by
  design, but it is still lossy and it is *transient*: it lives in the message
  list, so the NEXT compaction summarizes the summary. Everything the session
  learned the hard way — the root cause it chased for twenty turns, the command
  that finally worked, the constraint that made three approaches impossible —
  degrades once per compaction cycle and is gone from every future session.

  Memory, by contrast, is durable and cross-session (`Memory.Store` → SQLite).
  The fix is to write the knowledge down *before* the window is rewritten, which
  is what grok-build's `session/helpers/memory_flush.rs` and hermes-agent's
  `on_pre_compress` hook both do.

  ## Design

      warn_at ─────────── flush_at ─────── compact_at
                             ▲                 ▲
                        write notes       fold history

  * **`should_flush?/2`** fires in a band strictly BELOW `compact_at`, so the
    flush completes while the evidence is still in context. The band is
    `flush_at/1 .. compact_at`, and `flush_at/1` is
    `compact_at - :memory_flush_margin_tokens` (default #{12_000}), clamped so it
    can never sit below `warn_at/1` or above `compact_at`.

  * **A once-per-compaction-cycle latch.** `begin/1` claims the cycle and
    returns `:ok` exactly once; every subsequent call returns
    `{:error, :already_flushed}` until `reset_cycle/1` is called (which the
    compaction hook does after it folds history, opening the next cycle). Without
    this a session parked in the flush band would re-flush on every iteration.

  * **A dedupe gate.** Every candidate note is checked against what is already
    remembered (`Memory.recall/2` + keyword Jaccard) and against the other
    candidates in the same batch. Memory that repeats itself is memory that
    stops being read.

  * **No LLM call on the default path.** `run/2` harvests notes from the
    messages themselves with `harvest/1`. That keeps the flush free, synchronous
    and testable. `flush_message/1` is the optional LLM-driven variant for
    callers that would rather spend a turn asking the model what mattered.

  ## Wiring (owned by the loop, not by this module)

  This module is deliberately pure of loop concerns. The call site needs three
  lines in `Agent.Loop.ProactiveCompaction` — see `hook_contract/0` for the
  exact shape.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Memory

  # Reuses the application-owned ETS table (application.ex:235) so the latch
  # survives for the life of the node without adding a supervised process.
  @table :osa_compactor_state

  @default_margin_tokens 12_000
  @default_max_notes 8

  # A durable note is a sentence, not a paragraph and not a fragment.
  @min_note_chars 20
  @max_note_chars 300

  # Jaccard overlap at/above which a candidate is considered already remembered.
  @dupe_threshold 0.7

  # How many existing memories to compare a candidate against.
  @recall_limit 5

  # Only the tail of the conversation is harvested: older turns have already
  # been through a previous flush cycle.
  @max_messages_scanned 200

  # ── Patterns: what counts as hard-won knowledge ──────────────────────────
  #
  # These deliberately target CONCLUSIONS, not narration. "I will now read the
  # file" is worthless; "the root cause was the stale symlink" is the whole
  # point of the session. Each pattern maps to the memory category it implies.

  @lesson_patterns [
    ~r/\b(?:the )?root cause (?:was|is)\b/i,
    ~r/\bit turns out\b/i,
    ~r/\bthe (?:bug|problem|issue|failure) (?:was|is)\b/i,
    ~r/\bthe fix (?:was|is)\b/i,
    ~r/\bfixed by\b/i,
    ~r/\bthe workaround (?:was|is)\b/i,
    ~r/\bgotcha:/i,
    ~r/\bcaveat:/i
  ]

  @decision_patterns [
    ~r/\bwe (?:decided|chose|settled on)\b/i,
    ~r/\bi (?:decided|chose) to\b/i,
    ~r/\bgoing with\b/i,
    ~r/\bthe decision (?:was|is)\b/i
  ]

  @constraint_patterns [
    ~r/\bmust not\b/i,
    ~r/\bnever (?:run|use|call|edit|commit)\b/i,
    ~r/\bonly works (?:if|when|with)\b/i,
    ~r/\bdoes not work (?:with|on|when)\b/i,
    ~r/\brequires\b.*\bbefore\b/i,
    ~r/\bis not on (?:the )?PATH\b/i
  ]

  @categories [
    {:lesson, @lesson_patterns},
    {:decision, @decision_patterns},
    {:context, @constraint_patterns}
  ]

  # Narration/noise that must never become a durable note even when it happens
  # to contain a trigger phrase.
  @noise_markers [
    "<system-reminder>",
    "[compact boundary]",
    "let me ",
    "i'll now ",
    "i will now ",
    "tool_result",
    "```"
  ]

  @type report :: %{
          saved: non_neg_integer(),
          candidates: non_neg_integer(),
          duplicates: non_neg_integer(),
          rejected: non_neg_integer()
        }

  # ── Thresholds ───────────────────────────────────────────────────────────

  @doc """
  Token count at which the pre-compaction flush should fire.

  Strictly below `CompactionThresholds.compact_at/1` and never below
  `CompactionThresholds.warn_at/1`, so the flush always gets a window of
  iterations in which to run before history is folded.
  """
  @spec flush_at(pos_integer()) :: pos_integer()
  def flush_at(context_window) when is_integer(context_window) and context_window > 0 do
    compact_at = CompactionThresholds.compact_at(context_window)
    warn_at = CompactionThresholds.warn_at(context_window)

    compact_at
    |> Kernel.-(margin_tokens())
    |> max(warn_at)
    |> min(compact_at - 1)
    |> max(1)
  end

  @doc """
  Whether a flush should fire for this state.

  True only when the feature is enabled, usage sits at/above `flush_at/1` but
  below `compact_at`, and this compaction cycle has not already flushed.

  `state` is the loop state map; `context_window` the provider's window.
  """
  @spec should_flush?(map(), term()) :: boolean()
  def should_flush?(_state, context_window)
      when not is_integer(context_window) or context_window <= 0,
      do: false

  def should_flush?(state, context_window) when is_map(state) do
    if enabled?() do
      tokens = estimated_tokens(state)

      tokens >= flush_at(context_window) and
        tokens < CompactionThresholds.compact_at(context_window) and
        not flushed?(session_of(state))
    else
      false
    end
  rescue
    e ->
      Logger.debug("[memory_flush] should_flush? failed: #{inspect(e)}")
      false
  end

  def should_flush?(_state, _cw), do: false

  # ── Once-per-cycle latch ─────────────────────────────────────────────────

  @doc """
  Claim this compaction cycle's flush. Returns `:ok` exactly once per cycle;
  `{:error, :already_flushed}` after that, until `reset_cycle/1`.

  Atomic (`:ets.insert_new/2`), so two concurrent iterations of the same session
  cannot both claim it.
  """
  @spec begin(term()) :: :ok | {:error, :already_flushed}
  def begin(session_id) do
    ensure_table()

    if :ets.insert_new(@table, {latch_key(session_id), System.monotonic_time(:millisecond)}) do
      :ok
    else
      {:error, :already_flushed}
    end
  rescue
    _ -> :ok
  end

  @doc "True when this compaction cycle has already flushed."
  @spec flushed?(term()) :: boolean()
  def flushed?(session_id) do
    ensure_table()
    :ets.lookup(@table, latch_key(session_id)) != []
  rescue
    _ -> false
  end

  @doc """
  Open the next compaction cycle. Call this immediately AFTER a compaction has
  folded history, so the next approach to the threshold flushes again.
  """
  @spec reset_cycle(term()) :: :ok
  def reset_cycle(session_id) do
    ensure_table()
    :ets.delete(@table, latch_key(session_id))
    :ok
  rescue
    _ -> :ok
  end

  # ── The flush itself ─────────────────────────────────────────────────────

  @doc """
  Harvest durable notes from `messages` and persist the non-duplicate ones.

  Claims the cycle latch first, so calling this on every loop iteration is safe:
  only the first call in a cycle does any work.

  Options:
    * `:session_id` — session that owns the latch and tags the memories
    * `:limit`      — max notes to persist (default #{@default_max_notes})
    * `:force`      — bypass the latch (for `/flush`-style manual invocation)

  Returns `{:ok, report}` or `{:skipped, reason}`.
  """
  @spec run([map()], keyword()) :: {:ok, report()} | {:skipped, atom()}
  def run(messages, opts \\ [])

  def run(messages, opts) when is_list(messages) and is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    limit = Keyword.get(opts, :limit, max_notes())

    claim =
      if Keyword.get(opts, :force, false), do: :ok, else: begin(session_id)

    case claim do
      {:error, :already_flushed} ->
        {:skipped, :already_flushed}

      :ok ->
        candidates = messages |> harvest() |> Enum.take(limit)

        report =
          Enum.reduce(candidates, blank_report(length(candidates)), fn note, acc ->
            persist(note, session_id, acc)
          end)

        if report.saved > 0 do
          Logger.info(
            "[memory_flush] wrote #{report.saved} durable note(s) before compaction " <>
              "(#{report.duplicates} already known, #{report.rejected} rejected)"
          )
        end

        {:ok, report}
    end
  end

  def run(_messages, _opts), do: {:skipped, :bad_input}

  @doc """
  Extract durable-note candidates from a message list, newest-relevant first.

  Pure and side-effect free — this is the half that is worth unit testing.
  Returns a list of `%{category: atom, content: String.t()}`.
  """
  @spec harvest([map()]) :: [%{category: atom(), content: String.t()}]
  def harvest(messages) when is_list(messages) do
    messages
    |> Enum.take(-@max_messages_scanned)
    |> Enum.flat_map(&sentences_of/1)
    |> Enum.flat_map(&classify/1)
    |> dedupe_batch()
  end

  def harvest(_), do: []

  @doc """
  The optional LLM-driven variant: a synthetic user turn asking the model to
  write down what it learned, using the `memory_save` tool.

  Returned in the same shape as
  `Agent.Loop.ProactiveCompaction.continuation_message/1` (synthetic, with a
  metadata marker) so transcript rendering and telemetry can tell it apart from
  a real user prompt. Callers that use this instead of `run/2` are responsible
  for the latch (`begin/1`).
  """
  @spec flush_message(keyword()) :: map()
  def flush_message(opts \\ []) do
    remaining = Keyword.get(opts, :remaining_tokens)

    urgency =
      if is_integer(remaining),
        do: " You have roughly #{remaining} tokens of context left before that happens.",
        else: ""

    %{
      role: "user",
      content:
        "[Memory flush] This conversation is about to be compacted — older turns will be " <>
          "replaced by a summary and the detail will be lost.#{urgency}\n\n" <>
          "Before that happens, call `memory_save` for each thing this session learned that " <>
          "would still be true and still be useful in a FUTURE session: root causes you " <>
          "found, fixes that worked, constraints you discovered, decisions you made and why, " <>
          "and commands/paths that turned out to matter.\n\n" <>
          "Write one memory per fact, stated as a standalone sentence that makes sense with " <>
          "no other context. Do NOT save narration, progress updates, or anything already " <>
          "obvious from the code. If nothing durable was learned, say so and save nothing.",
      synthetic: true,
      metadata: %{memory_flush: true}
    }
  end

  @doc """
  The exact hook the loop needs, as documentation for the owner of
  `Agent.Loop.ProactiveCompaction`.

  Returns a map describing the two call sites. Kept as code (not prose in a
  changelog) so it stays greppable and cannot drift silently.
  """
  @spec hook_contract() :: map()
  def hook_contract do
    %{
      before_compaction: %{
        where: "Agent.Loop.ProactiveCompaction — same place should_microcompact?/2 is consulted",
        call:
          "if Memory.Flush.should_flush?(state, context_window), " <>
            "do: Memory.Flush.run(state.messages, session_id: state.session_id)",
        why: "writes durable notes while the evidence is still in the window"
      },
      after_compaction: %{
        where:
          "Agent.Loop.ProactiveCompaction.compact/3, success branch, next to reset_failures/1",
        call: "Memory.Flush.reset_cycle(session_id)",
        why: "opens the next compaction cycle so the next approach flushes again"
      }
    }
  end

  # ── Harvest internals ────────────────────────────────────────────────────

  defp sentences_of(msg) do
    role = to_string(Map.get(msg, :role) || Map.get(msg, "role") || "")

    if role in ["user", "assistant"] do
      msg
      |> content_text()
      |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
      |> Enum.map(&String.trim/1)
    else
      []
    end
  end

  defp content_text(msg) do
    case Map.get(msg, :content) || Map.get(msg, "content") do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        blocks
        |> Enum.map(fn
          %{type: t, text: text} when t in [:text, "text"] and is_binary(text) -> text
          %{"type" => "text", "text" => text} when is_binary(text) -> text
          _ -> ""
        end)
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp classify(sentence) do
    cond do
      not well_sized?(sentence) -> []
      noise?(sentence) -> []
      true -> match_category(sentence)
    end
  end

  defp match_category(sentence) do
    Enum.find_value(@categories, [], fn {category, patterns} ->
      if Enum.any?(patterns, &Regex.match?(&1, sentence)) do
        [%{category: category, content: sentence}]
      end
    end)
  end

  defp well_sized?(sentence) do
    len = String.length(sentence)
    len >= @min_note_chars and len <= @max_note_chars
  end

  defp noise?(sentence) do
    down = String.downcase(sentence)
    Enum.any?(@noise_markers, &String.contains?(down, &1))
  end

  # Within one batch, keep the first of any two notes that say the same thing.
  defp dedupe_batch(candidates) do
    candidates
    |> Enum.reduce({[], []}, fn cand, {kept, keysets} ->
      ks = keyword_set(cand.content)

      if Enum.any?(keysets, &(jaccard(&1, ks) >= @dupe_threshold)) do
        {kept, keysets}
      else
        {[cand | kept], [ks | keysets]}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # ── Persistence + dedupe against existing memory ─────────────────────────

  defp persist(%{category: category, content: content}, session_id, acc) do
    if already_remembered?(content) do
      %{acc | duplicates: acc.duplicates + 1}
    else
      case Memory.save(content,
             category: category,
             source: :agent,
             session_id: session_id,
             signal_weight: 0.7,
             tags: ["pre_compaction", "flush", to_string(category)]
           ) do
        {:ok, _entry} -> %{acc | saved: acc.saved + 1}
        _ -> %{acc | rejected: acc.rejected + 1}
      end
    end
  rescue
    e ->
      Logger.debug("[memory_flush] save failed: #{Exception.message(e)}")
      %{acc | rejected: acc.rejected + 1}
  end

  @doc """
  True when memory already holds an entry that says substantially the same
  thing (keyword Jaccard ≥ #{@dupe_threshold}).

  Public because it is the gate that keeps repeated flushes from turning memory
  into a transcript, and is therefore worth pinning directly.
  """
  @spec already_remembered?(String.t()) :: boolean()
  def already_remembered?(content) when is_binary(content) do
    target = keyword_set(content)

    if MapSet.size(target) == 0 do
      false
    else
      case Memory.recall(content, limit: @recall_limit) do
        {:ok, entries} when is_list(entries) ->
          Enum.any?(entries, fn entry ->
            entry
            |> entry_content()
            |> keyword_set()
            |> jaccard(target)
            |> Kernel.>=(@dupe_threshold)
          end)

        _ ->
          false
      end
    end
  rescue
    _ -> false
  end

  def already_remembered?(_), do: false

  defp entry_content(entry) when is_map(entry) do
    to_string(Map.get(entry, :content) || Map.get(entry, "content") || "")
  end

  defp entry_content(_), do: ""

  # ── Text helpers ─────────────────────────────────────────────────────────

  @stop_words ~w(a an the and or but in on at to for of is are was were be been
                 being have has had do does did will would could should may might
                 this that these those it its as if then than so not no there here
                 we you they i our your their with from by about into out up down)

  defp keyword_set(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_\/\.\-]+/, trim: true)
    # `.` `-` `_` `/` are kept INSIDE a token so `lib/app/auth.ex` stays one
    # keyword, but a trailing sentence period would otherwise make `binary.` and
    # `binary` two different keywords — which is enough to push two restatements
    # of the same fact below the dedupe threshold.
    |> Enum.map(&String.trim(&1, "."))
    |> Enum.map(&String.trim(&1, "-"))
    |> Enum.reject(&(String.length(&1) < 3 or &1 in @stop_words))
    |> MapSet.new()
  end

  defp jaccard(a, b) do
    inter = MapSet.size(MapSet.intersection(a, b))
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 0.0, else: inter / union
  end

  # ── Config / plumbing ────────────────────────────────────────────────────

  defp blank_report(candidates) do
    %{saved: 0, candidates: candidates, duplicates: 0, rejected: 0}
  end

  defp latch_key(session_id) when is_binary(session_id) and session_id != "",
    do: {:memory_flush, session_id}

  defp latch_key(_), do: {:memory_flush, {:pid, self()}}

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp enabled?,
    do: Application.get_env(:optimal_system_agent, :memory_flush_enabled, true) == true

  defp margin_tokens do
    case Application.get_env(
           :optimal_system_agent,
           :memory_flush_margin_tokens,
           @default_margin_tokens
         ) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_margin_tokens
    end
  end

  defp max_notes do
    case Application.get_env(:optimal_system_agent, :memory_flush_max_notes, @default_max_notes) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_notes
    end
  end

  defp session_of(state), do: Map.get(state, :session_id)

  # Mirrors ProactiveCompaction.estimated_tokens/1: the provider's reported
  # input size when we have it, the local heuristic otherwise.
  defp estimated_tokens(state) do
    last = Map.get(state, :last_input_tokens, 0)

    if is_integer(last) and last > 0 do
      last
    else
      OptimalSystemAgent.Agent.ContextEngine.Router.estimate_tokens(Map.get(state, :messages, []))
    end
  end
end
