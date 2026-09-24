defmodule OptimalSystemAgent.Learning.DoubleLoop do
  @moduledoc """
  Double-loop learning: turns a session's buffered pain events
  (`OptimalSystemAgent.Learning.PainSink`) into durable, de-duplicated
  lessons through the existing memory system, at session end and at
  compaction.

  ## Why "double-loop"

  Single-loop learning already exists in OSA — `OptimalSystemAgent.Memory.Learning`'s
  SICA cycle observes individual tool calls and captures per-tool error
  patterns as they happen. This is the OUTER loop: instead of reacting
  turn-by-turn, it looks back over a session's accumulated friction —
  repeated probes, re-verification loops, commands that needed a retry to
  succeed, slow searches, wrong checkouts, user corrections — and writes ONE
  concise, reusable rule per distinct pattern, not a blow-by-blow transcript.

  ## Lifecycle

    1. Something calls `PainSink.record/4` during the session — today that is
       `OptimalSystemAgent.Agent.Loop.ToolRetry` on a recovered transient
       failure, and the `pain_observer_*` hooks in
       `OptimalSystemAgent.Agent.Hooks.Handlers` — or, eventually, a richer
       dedicated pain channel.
    2. `flush/2` runs at `:session_end` and `:post_compact`
       (`Agent.Hooks.Handlers.pain_lesson_flush/1` and
       `pain_lesson_flush_on_compact/1`). It reads the session's buffered
       events, BUCKETS them by `kind` (the dedup unit — see `bucket/1`), and
       turns each bucket meeting `:min_occurrences` into ONE lesson string via
       a deterministic, per-kind template (`lesson_text/2` — never an LLM
       call: this runs at shutdown/compaction time and must not add latency
       or cost there).
    3. Each lesson is written with `OptimalSystemAgent.Memory.save/2`,
       `category: :lesson`. Cross-session de-duplication and consolidation is
       NOT reimplemented here — it is `Memory.Store`'s existing Mem0-style
       ADD/UPDATE/NOOP keyword-overlap consolidation, which is exactly why
       every template below is deliberately generic, stable text (only the
       occurrence COUNT varies): near-identical lessons from this session and
       future ones are meant to collapse into updates of the same entry
       rather than piling up as near-duplicates.
    4. The session's pain buffer is cleared (`PainSink.clear/1`) so the next
       flush starts empty — lessons are consolidated, not appended forever.
    5. Provenance (`session_id`, `created_at`) is exactly what
       `Memory.save/2` already stores on every entry; nothing extra is
       needed here.
    6. Retrieval into future sessions is exactly `Agent.Context`'s existing
       `recall_scored/2` (`## Long-term Memory` block, relevance-ranked and
       token-capped, placed in the volatile system tail) — a `:lesson` is
       just another memory category, so it is already retrieved by relevance
       and budget with no additional plumbing.

  ## Review / prune

  `list_lessons/1` and `prune_lesson/1` back `mix osa.lessons` (list, prune
  `<id>`, prune `--all`) — the reviewable, editable, deletable surface the
  user owns.

  ## Secrets / file contents

  Lesson text is 100% static per kind (only the numeric occurrence count is
  interpolated) — the sanitised `detail` on each `PainEvent` is never
  echoed into a lesson. This is a second, independent guarantee on top of
  `PainEvent.sanitize/1`.
  """

  require Logger

  alias OptimalSystemAgent.Learning.{PainEvent, PainSink}
  alias OptimalSystemAgent.Memory

  @default_min_occurrences 1
  @default_list_limit 500

  @doc """
  Consolidate a session's buffered pain events into lessons and clear the
  buffer.

  Best-effort: every step is guarded so a storage hiccup degrades to "no
  lesson written this time" rather than crashing the session-end/compaction
  path that calls it.

  Options:
    * `:min_occurrences` — a kind must have at least this many buffered
      events before it becomes a lesson (default #{@default_min_occurrences}).

  Returns `{:ok, [lesson_text, ...]}`.
  """
  @spec flush(String.t(), keyword()) :: {:ok, [String.t()]}
  def flush(session_id, opts \\ [])

  def flush(session_id, opts) when is_binary(session_id) do
    min_occurrences = Keyword.get(opts, :min_occurrences, @default_min_occurrences)

    saved =
      session_id
      |> PainSink.events()
      |> bucket()
      |> Enum.filter(fn {_kind, bucket_events} -> length(bucket_events) >= min_occurrences end)
      |> Enum.map(fn {kind, bucket_events} -> save_lesson(session_id, kind, bucket_events) end)
      |> Enum.filter(&is_binary/1)

    PainSink.clear(session_id)

    {:ok, saved}
  rescue
    e ->
      Logger.warning(
        "[double_loop] flush failed for #{inspect(session_id)}: #{Exception.message(e)}"
      )

      {:ok, []}
  end

  def flush(_session_id, _opts), do: {:ok, []}

  @doc "Group buffered pain events by kind — the dedup unit for one flush."
  @spec bucket([PainEvent.t()]) :: [{PainEvent.kind(), [PainEvent.t()]}]
  def bucket(events) do
    events
    |> Enum.group_by(& &1.kind)
    |> Enum.to_list()
  end

  defp save_lesson(session_id, kind, bucket_events) do
    count = length(bucket_events)
    text = lesson_text(kind, count)

    case Memory.save(text,
           category: :lesson,
           tags: ["learning", "auto", to_string(kind)],
           source: :system,
           session_id: session_id,
           signal_weight: signal_weight_for(count)
         ) do
      {:ok, _entry} -> text
      # NOOP — Memory.Store already holds an effectively-identical lesson.
      # That is success from THIS module's perspective (durably recorded,
      # just not a new row); still report the text as "saved this flush".
      {:error, :duplicate} -> text
      {:error, _reason} -> nil
    end
  end

  # Stable, generic wording per kind so repeat occurrences (this session and
  # future ones) keep enough keyword overlap for `Memory.Store`'s Mem0-style
  # consolidation to merge/update instead of piling up near-duplicates. Only
  # the occurrence COUNT varies — see the moduledoc's "Secrets / file
  # contents" note for why per-event detail is never interpolated here.
  defp lesson_text(:repeated_probe, count) do
    "Noticed the same probe repeated #{count}x before changing approach — " <>
      "check the result of the first attempt before re-issuing an identical call."
  end

  defp lesson_text(:reverification_loop, count) do
    "Re-ran the same verification/check #{count}x in a row — " <>
      "trust a clean result and move on instead of re-verifying without new evidence."
  end

  defp lesson_text(:command_fix, count) do
    "A command failed transiently and needed a retry to succeed (#{count}x this " <>
      "session) — prefer the retried form or add the missing wait/precondition up front."
  end

  defp lesson_text(:wrong_checkout, count) do
    "Started work against the wrong checkout/branch and had to switch (#{count}x) — " <>
      "confirm the working directory and branch before running commands that depend on it."
  end

  defp lesson_text(:slow_search, count) do
    "A search over the workspace was slow (#{count}x) — " <>
      "exclude build/dependency directories (_build, deps, node_modules, .git, target) " <>
      "from searches by default."
  end

  defp lesson_text(:user_correction, count) do
    "The user corrected the approach #{count}x this session — " <>
      "re-read a correction fully before continuing rather than repeating the same move."
  end

  defp lesson_text(:other, count) do
    "Hit #{count} unclassified friction event(s) this session worth a second look."
  end

  defp signal_weight_for(count), do: min(0.4 + count * 0.1, 0.9)

  @doc "List saved lessons, newest first (backs `mix osa.lessons list`)."
  @spec list_lessons(pos_integer()) :: {:ok, [map()]}
  def list_lessons(limit \\ @default_list_limit) do
    case Memory.recent(limit) do
      {:ok, entries} -> {:ok, Enum.filter(entries, &(Map.get(&1, :category) == "lesson"))}
      other -> other
    end
  end

  @doc "Delete one lesson by id (backs `mix osa.lessons prune <id>`)."
  @spec prune_lesson(String.t()) :: :ok | {:error, term()}
  def prune_lesson(id) when is_binary(id), do: Memory.delete(id)
end
