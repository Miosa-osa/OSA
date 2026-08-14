defmodule OptimalSystemAgent.Agent.CompactionEvents do
  @moduledoc """
  Lifecycle events for context compaction, emitted on BOTH event transports.

  ## Why both

  OSA has two disjoint event transports (see `OptimalSystemAgent.Events.TuiForwarder`):

    * `Phoenix.PubSub` on `"osa:session:<id>"` — what the SSE stream
      (`agent_routes.ex` `GET /api/v1/stream/:id`, and its `session_routes.ex`
      alias) subscribes to, and therefore the ONLY thing the Rust TUI sees.
    * `Events.Bus` — what the CLI channel renderer listens on.

  Compaction used to emit on the Bus alone (`Loop.ProactiveCompaction.emit_event/4`),
  which made it completely invisible in the TUI: the turn simply froze for
  minutes with no explanation. Every function here dual-emits, mirroring
  `Loop.ToolExecutor`'s convention, so the same fact reaches both surfaces.

  ## The event contract

  Four events, all carrying `session_id`. The SSE loop unwraps
  `%{type: :system_event, event: sub}` so the wire event name is the sub-name:

    * `compaction_started`   — `%{trigger: "auto" | "manual", tokens_before}`
    * `compaction_progress`  — `%{chunk_index, chunk_total}` (1-based, inclusive)
    * `compaction_completed` — `%{tokens_before, tokens_after, messages_before,
                                  messages_after, duration_ms}`
    * `compaction_failed`    — `%{reason, duration_ms}`

  ## On `compaction_progress` — measured, never decorative

  This event is emitted ONLY from the divide-and-conquer chunked cold-zone
  summarizer (`Compactor.call_key_facts_llm_chunked/1`), which genuinely walks
  N independent LLM calls and so has a real `chunk_index / chunk_total` ratio.

  It is deliberately NOT emitted from:

    * `Loop.ProactiveCompaction.compact/3` (the `/compact` manual path) — that
      is a SINGLE summarizer call. There is no ratio to report.
    * the compactor's step pipeline (`micro_compact → … → emergency_truncate`) —
      the pipeline stops as soon as it is under budget, so "step 3 of 6" is a
      ladder that may exit at any rung, not a monotonic fraction of known work.

  Consumers must therefore treat progress as OPTIONAL and render a bar only
  once a real `compaction_progress` arrives. A compaction with no progress
  events gets a spinner and an elapsed timer and nothing else — an animated bar
  that is not tracking measured work is a lie about the state of the system.
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus

  @typedoc "What asked for this compaction."
  @type trigger :: :auto | :manual

  @doc """
  Compaction is starting. `tokens_before` is the pre-compaction estimate.
  """
  @spec started(String.t() | nil, trigger(), non_neg_integer()) :: :ok
  def started(session_id, trigger, tokens_before) do
    emit(session_id, :compaction_started, %{
      trigger: to_string(trigger),
      tokens_before: tokens_before
    })
  end

  @doc """
  One chunk of a divide-and-conquer summarization finished.

  `chunk_index` is 1-based and inclusive of the chunk just completed, so
  `chunk_index == chunk_total` means the last chunk is done. Callers must only
  use this where both numbers are real.
  """
  @spec progress(String.t() | nil, pos_integer(), pos_integer()) :: :ok
  def progress(session_id, chunk_index, chunk_total)
      when is_integer(chunk_index) and is_integer(chunk_total) and chunk_total > 0 do
    emit(session_id, :compaction_progress, %{
      chunk_index: min(chunk_index, chunk_total),
      chunk_total: chunk_total
    })
  end

  def progress(_session_id, _idx, _total), do: :ok

  @doc """
  Compaction finished successfully. All four counts are measured, never guessed.
  """
  @spec completed(String.t() | nil, keyword()) :: :ok
  def completed(session_id, fields) do
    # Invalidate every redundant-read suppression recorded before this point:
    # `file_read` answers "unchanged since your last read" only while the earlier
    # read is still verbatim in the transcript, and a compaction is exactly the
    # event that can remove it. Best-effort — never allowed to fail a compaction.
    _ = OptimalSystemAgent.Tools.FileState.bump_epoch(session_id)

    emit(session_id, :compaction_completed, %{
      tokens_before: Keyword.get(fields, :tokens_before, 0),
      tokens_after: Keyword.get(fields, :tokens_after, 0),
      messages_before: Keyword.get(fields, :messages_before, 0),
      messages_after: Keyword.get(fields, :messages_after, 0),
      duration_ms: Keyword.get(fields, :duration_ms, 0)
    })
  end

  @doc """
  Compaction failed. The conversation is unchanged — say so rather than letting
  the running indicator silently vanish, which reads as success.
  """
  @spec failed(String.t() | nil, term(), non_neg_integer()) :: :ok
  def failed(session_id, reason, duration_ms) do
    emit(session_id, :compaction_failed, %{
      reason: describe(reason),
      duration_ms: duration_ms
    })
  end

  @doc """
  The session id the current compaction run belongs to.

  `Compactor.run_pipeline/6` stashes this in the process dictionary for the
  duration of a run so deeply-nested helpers (the chunked summarizer) can emit
  session-scoped progress without threading the id through six call layers.
  """
  @spec current_session_id() :: String.t() | nil
  def current_session_id do
    case Process.get(:osa_compact_session_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------

  defp emit(session_id, event, data) when is_binary(session_id) and session_id != "" do
    payload =
      data
      |> Map.put(:type, :system_event)
      |> Map.put(:event, event)
      |> Map.put(:session_id, session_id)

    # PubSub FIRST — this is the transport the TUI actually consumes. The Bus
    # emit below is for the CLI renderer; a failure in one must not skip the
    # other, hence the separate rescue in each.
    broadcast(session_id, payload)
    bus_emit(payload)

    :ok
  end

  # No session id — there is no topic to broadcast on. Still emit on the Bus so
  # the CLI channel (which is not session-scoped) can render it.
  defp emit(_session_id, event, data) do
    bus_emit(Map.put(data, :event, event))
    :ok
  end

  defp broadcast(session_id, payload) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, payload}
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp bus_emit(payload) do
    Bus.emit(:system_event, Map.delete(payload, :type))
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp describe(reason) when is_binary(reason), do: reason

  defp describe(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp describe(reason), do: inspect(reason)
end
