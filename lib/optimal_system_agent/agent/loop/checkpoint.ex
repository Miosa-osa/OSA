defmodule OptimalSystemAgent.Agent.Loop.Checkpoint do
  @moduledoc """
  Loop state persistence for crash recovery.

  Persists enough state after each completed tool-result cycle so that
  a crash-restarted Loop can resume without losing conversation context.
  """
  require Logger

  alias OptimalSystemAgent.Utils.Text

  @doc "Returns the directory where checkpoint files are stored."
  def checkpoint_dir do
    Application.get_env(:optimal_system_agent, :checkpoint_dir, "~/.osa/checkpoints")
    |> Path.expand()
  end

  @doc """
  Returns the full path to the checkpoint file for the given session.

  The id is run through `sanitize_session/1` — the same guard the rewind path
  below already applied — so a session id carrying `/` or `..` cannot steer the
  write (or the `File.rm` in `clear_checkpoint/1`) outside `checkpoint_dir/0`.
  """
  def checkpoint_path(session_id) do
    Path.join(checkpoint_dir(), "#{sanitize_session(session_id)}.json")
  end

  # Every field the crash-recovery record carries. `checkpoint_state/1` writes
  # ALL of them, so a caller that supplies only some of them is asking for the
  # rest to be overwritten with their defaults — which for the spend
  # accumulators means $0 and for `max_budget_usd` means *uncapped*.
  #
  # Rather than trusting callers to remember that, the writer refuses to be a
  # partial writer: anything it wasn't given is filled from the record already
  # on disk (see `ensure_full_record/1`), so an omitted field can only ever be
  # preserved, never zeroed. `update_checkpoint/1` is the named, documented way
  # to ask for a partial update.
  @record_keys [
    :session_id,
    :messages,
    :iteration,
    :plan_mode,
    :turn_count,
    :session_cost_usd,
    :session_input_tokens,
    :session_output_tokens,
    :session_cache_creation_tokens,
    :session_cache_read_tokens,
    :max_budget_usd,
    :started_at
  ]

  @doc """
  Update *some* fields of a session's crash-recovery checkpoint, leaving every
  field not supplied at its currently-persisted value.

  This is the path a conversation-only restore (`/rewind`, `unrevert`) must
  take: it rewrites `messages`/`iteration`/`turn_count` and must not touch the
  session's accounting.
  """
  @spec update_checkpoint(map()) :: :ok
  def update_checkpoint(%{session_id: session_id} = partial)
      when is_binary(session_id) and session_id != "" do
    session_id
    |> persisted_record()
    |> Map.merge(Map.take(partial, @record_keys))
    |> checkpoint_state()

    :ok
  end

  def update_checkpoint(_), do: :ok

  @doc """
  Write a checkpoint for the given loop state.

  Writes the FULL record. A map missing any `@record_keys` field is completed
  from the persisted record instead of from defaults — a partial map must never
  be able to zero the spend accumulators or drop the budget cap.
  """
  def checkpoint_state(state) do
    state = ensure_full_record(state)

    data = %{
      session_id: state.session_id,
      messages: state.messages,
      iteration: state.iteration,
      plan_mode: state.plan_mode,
      turn_count: state.turn_count,
      # Spend accumulators (audit gap C2): persist the running budget totals so a
      # crash-restarted loop resumes with a NON-zero spend and a `max_budget_usd`
      # cap keeps holding. Without this a $48-of-$50 run resumes at $0 and blows
      # past the cap. Pricing/accounting math is unchanged — we only persist the
      # totals `Loop.Accounting` already maintains on the state.
      session_cost_usd: Map.get(state, :session_cost_usd, 0.0),
      session_input_tokens: Map.get(state, :session_input_tokens, 0),
      session_output_tokens: Map.get(state, :session_output_tokens, 0),
      session_cache_creation_tokens: Map.get(state, :session_cache_creation_tokens, 0),
      session_cache_read_tokens: Map.get(state, :session_cache_read_tokens, 0),
      # Budget cap (audit gap D2 restore half): persist the CAP itself, not just
      # the accumulated spend. Without this a $50 cap is re-read fresh from
      # opts→app env each Loop.init, so a crash/restart of a run started with an
      # explicit cap would silently reset it (app-env default is nil = uncapped).
      # nil is preserved (uncapped stays uncapped).
      max_budget_usd: Map.get(state, :max_budget_usd),
      started_at: serialize_started_at(Map.get(state, :started_at)),
      checkpointed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    dir = checkpoint_dir()
    File.mkdir_p!(dir)

    path = checkpoint_path(state.session_id)
    # Sanitize messages to valid UTF-8 before JSON encoding — codebase context
    # blocks may contain non-UTF-8 bytes from binary file reads.
    sanitized =
      update_in(data, [:messages], fn msgs ->
        Enum.map(msgs, fn
          %{content: c} = m when is_binary(c) -> %{m | content: sanitize_utf8(c)}
          %{"content" => c} = m when is_binary(c) -> %{m | "content" => sanitize_utf8(c)}
          m -> m
        end)
      end)

    # Atomic write: write to a temp file then rename. rename(2) is atomic on
    # POSIX, so a crash mid-write leaves either the intact old file or the
    # intact new one — never a torn file that fails to decode on resume.
    # Unique temp path per writer so a concurrent /rewind restore and periodic
    # crash-checkpoint never share one ".tmp" inode (which would tear the file).
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, Jason.encode!(sanitized), [:utf8])
    File.rename!(tmp, path)

    # Also mirror the running spend into the durable between-turn sidecar. The
    # crash-recovery checkpoint above is CLEARED at every clean turn boundary
    # (Loop.terminate/2), so on a resume AFTER a completed turn it is gone. The
    # spend sidecar is NOT cleared there, so accumulated spend survives a resume
    # too — and a `max_budget_usd` cap keeps holding across turns. Best-effort.
    persist_spend_sidecar(state)

    Logger.debug(
      "[loop] Checkpoint written for session #{state.session_id} at iteration #{state.iteration}"
    )
  rescue
    e ->
      Logger.warning("[loop] Checkpoint write failed: #{Exception.message(e)}")
  end

  @doc "Restore a checkpoint for the given session. Returns a map of state fields, or %{} if none exists."
  def restore_checkpoint(session_id) do
    path = checkpoint_path(session_id)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} ->
              raw_messages = if is_list(data["messages"]), do: data["messages"], else: []

              messages =
                Enum.map(raw_messages, fn
                  msg when is_map(msg) ->
                    for {k, v} <- msg, into: %{} do
                      {safe_key(k), v}
                    end

                  other ->
                    other
                end)

              %{
                messages: messages,
                iteration: data["iteration"] || 0,
                plan_mode: data["plan_mode"] || false,
                turn_count: data["turn_count"] || 0,
                # Spend accumulators (audit gap C2). Absent on pre-C2 checkpoints,
                # so default to zero — the loop's sidecar fallback then supplies
                # any post-turn spend.
                session_cost_usd: num(data["session_cost_usd"], 0.0),
                session_input_tokens: num(data["session_input_tokens"], 0),
                session_output_tokens: num(data["session_output_tokens"], 0),
                session_cache_creation_tokens: num(data["session_cache_creation_tokens"], 0),
                session_cache_read_tokens: num(data["session_cache_read_tokens"], 0),
                # Budget cap (audit gap D2). Absent on pre-D2 checkpoints → nil,
                # so Loop.init falls back to opts→app env. A persisted number wins
                # so a resumed run honors the cap it was started with.
                max_budget_usd: num_or_nil(data["max_budget_usd"]),
                started_at: data["started_at"]
              }

            {:error, _} ->
              Logger.warning("[loop] Checkpoint decode failed for session #{session_id}")
              %{}
          end

        {:error, _} ->
          %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  # Bounded key→atom conversion. Message maps only ever use a small fixed set of
  # atom keys, so to_existing_atom preserves behavior for legitimate files while
  # capping atom-table growth on a malformed/tampered file with thousands of
  # distinct keys (which could otherwise exhaust the atom table and crash the VM).
  defp safe_key(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> k
    end
  end

  defp safe_key(k), do: k

  # Coerce a checkpointed message's content to valid UTF-8.
  #
  # This used to return `valid` from the `{:error, valid, _}` and
  # `{:incomplete, valid, _}` clauses of `:unicode.characters_to_binary/2`,
  # dropping everything after the first undecodable byte with no marker and no
  # log — and `:incomplete` (a chunk boundary landing mid-sequence) is the
  # likely case, so what was lost was typically a message TAIL, not a stray
  # byte. A checkpoint exists to restore a conversation after a crash; a
  # silently shortened message is restored as if it were complete.
  #
  # Replacing bad bytes with U+FFFD preserves length and everything past the
  # damage, matching `ShellExecute.Handler`'s treatment of raw command output.
  defp sanitize_utf8(binary) when is_binary(binary), do: Text.scrub_utf8(binary)

  defp sanitize_utf8(other), do: other |> to_string() |> Text.scrub_utf8()

  # Complete a partial state map from the record already on disk.
  #
  # A full `%Loop{}` (every `@record_keys` field is a defstruct field) passes
  # through untouched, so the hot path is unchanged and a real turn can still
  # LOWER a counter. Only a caller that genuinely omitted a field pays a read,
  # and what it omitted is preserved rather than defaulted.
  defp ensure_full_record(state) when is_map(state) do
    case Enum.reject(@record_keys, &Map.has_key?(state, &1)) do
      [] ->
        state

      missing ->
        session_id = Map.get(state, :session_id)

        if is_binary(session_id) and session_id != "" do
          Logger.warning(
            "[loop] checkpoint_state/1 got a PARTIAL record (missing #{inspect(missing)}) — " <>
              "completing it from the persisted record instead of writing defaults over it"
          )

          session_id
          |> persisted_record()
          |> Map.merge(Map.take(state, @record_keys))
        else
          state
        end
    end
  end

  defp ensure_full_record(state), do: state

  # The record as it currently exists durably: the crash checkpoint, with the
  # never-cleared spend sidecar as the floor for the accumulators (the
  # checkpoint is deleted at every clean turn boundary, the sidecar is not, so
  # either one can be the fresher of the two). Spend only ever grows, so `max`
  # is the honest reconciliation.
  defp persisted_record(session_id) do
    prior = restore_checkpoint(session_id)
    spend = load_spend(session_id)

    %{
      session_id: session_id,
      messages: Map.get(prior, :messages, []),
      iteration: Map.get(prior, :iteration, 0),
      plan_mode: Map.get(prior, :plan_mode, false),
      turn_count: Map.get(prior, :turn_count, 0),
      session_cost_usd: max(Map.get(prior, :session_cost_usd, 0.0), spend.cost_usd),
      session_input_tokens: max(Map.get(prior, :session_input_tokens, 0), spend.input_tokens),
      session_output_tokens: max(Map.get(prior, :session_output_tokens, 0), spend.output_tokens),
      session_cache_creation_tokens:
        max(Map.get(prior, :session_cache_creation_tokens, 0), spend.cache_creation_tokens),
      session_cache_read_tokens:
        max(Map.get(prior, :session_cache_read_tokens, 0), spend.cache_read_tokens),
      max_budget_usd: Map.get(prior, :max_budget_usd),
      started_at: Map.get(prior, :started_at) || spend.started_at
    }
  end

  defp load_spend(session_id) do
    OptimalSystemAgent.Agent.SessionPersistence.load_spend(session_id)
  rescue
    _ ->
      %{
        cost_usd: 0.0,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_tokens: 0,
        cache_read_tokens: 0,
        started_at: nil
      }
  end

  # Coerce a possibly-nil / possibly-string JSON number into a number, else default.
  defp num(v, _default) when is_number(v), do: v
  defp num(_, default), do: default

  # Like num/2 but preserves nil (absent cap) instead of coercing to a default —
  # a nil `max_budget_usd` means "uncapped, fall back to opts→app env".
  defp num_or_nil(v) when is_number(v), do: v
  defp num_or_nil(_), do: nil

  # started_at may be a %DateTime{} on live state or an iso8601 string on a
  # restored one; normalize both to a string for the JSON payload.
  defp serialize_started_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_started_at(s) when is_binary(s), do: s
  defp serialize_started_at(_), do: nil

  # Mirror the running spend into the durable between-turn sidecar (never raises).
  #
  # This goes through `SessionPersistence.flush_spend/2` and NOT a locally-built
  # payload. `save_spend/2` overwrites the file, so a second writer with a
  # narrower shape silently deletes fields the other writer put there: this
  # function used to omit `tree_cost_usd`/`tree_cost_complete`, and because a
  # turn's final LLM round-trip makes no tool call, this mid-turn write was the
  # LAST one to touch the file on most runs. The published sidecar then lacked
  # the tree figure and lagged the true token count by one round-trip.
  defp persist_spend_sidecar(state) do
    OptimalSystemAgent.Agent.SessionPersistence.flush_spend(state.session_id, state)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Delete the checkpoint file for the given session."
  def clear_checkpoint(session_id) do
    path = checkpoint_path(session_id)

    File.rm(path)
    :ok
  rescue
    _ -> :ok
  end

  # ══════════════════════════════════════════════════════════════════════
  # Rewind checkpoints (/rewind UX)
  #
  # Unlike the single-file crash-recovery checkpoint above (which is
  # overwritten each tool cycle), rewind checkpoints keep a *history* of
  # snapshots — one taken before each user prompt. Each snapshot pairs the
  # conversation state (messages) with the code state at that moment,
  # captured as the HEAD of the FSCheckpoint shadow repo (`fs_head`).
  #
  # A user can later restore code, conversation, or both from any recent
  # snapshot. Retention is bounded (default 50 per session).
  # ══════════════════════════════════════════════════════════════════════

  @default_max_rewind 50
  @label_max_len 120

  @doc "Root directory for rewind checkpoint history."
  def rewind_dir do
    Application.get_env(:optimal_system_agent, :rewind_checkpoint_dir, "~/.osa/rewind")
    |> Path.expand()
  end

  @doc "Per-session directory holding rewind checkpoint files."
  def rewind_session_dir(session_id) do
    Path.join(rewind_dir(), sanitize_session(session_id))
  end

  defp max_rewind do
    try do
      OptimalSystemAgent.Settings.get("rewind_checkpoints_max_count", @default_max_rewind)
    rescue
      _ -> @default_max_rewind
    end
  end

  @doc """
  Create a rewind checkpoint from the given loop state. Meant to be called
  right *before* a user prompt is processed, so `state.messages` reflects the
  conversation as it was before that prompt.

  Options:
    * `:label`   — a human label (typically the user prompt); truncated
    * `:fs_head` — override the captured code HEAD (defaults to shadow repo)

  Returns `{:ok, id}` or `{:error, reason}`. Never raises.
  """
  def create_rewind_checkpoint(state, opts \\ []) do
    ts = System.system_time(:millisecond)
    id = "#{ts}_#{:crypto.strong_rand_bytes(3) |> Base.url_encode64(padding: false)}"

    fs_head =
      case Keyword.fetch(opts, :fs_head) do
        {:ok, v} -> v
        :error -> safe_fs_head()
      end

    messages = Map.get(state, :messages, [])

    entry = %{
      id: id,
      session_id: state.session_id,
      created_ms: ts,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      label: derive_label(Keyword.get(opts, :label)),
      iteration: Map.get(state, :iteration, 0),
      plan_mode: Map.get(state, :plan_mode, false),
      turn_count: Map.get(state, :turn_count, 0),
      message_count: length(messages),
      fs_head: fs_head,
      messages: sanitize_messages(messages)
    }

    dir = rewind_session_dir(state.session_id)
    File.mkdir_p!(dir)
    # Atomic write-then-rename so a crash never leaves a torn rewind point.
    path = Path.join(dir, id <> ".json")
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, Jason.encode!(entry), [:utf8])
    File.rename!(tmp, path)

    prune_rewind(state.session_id)

    Logger.debug("[rewind] Checkpoint #{id} created for session #{state.session_id}")
    {:ok, id}
  rescue
    e ->
      Logger.warning("[rewind] Checkpoint create failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  List rewind checkpoints for a session, newest first. Each entry is metadata
  only (no full message payload) — `id`, `label`, `created_at`, `iteration`,
  `message_count`, and whether a code snapshot (`has_code`) is available.
  """
  def list_rewind_checkpoints(session_id, limit \\ @default_max_rewind) do
    dir = rewind_session_dir(session_id)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn file ->
          case read_entry(Path.join(dir, file)) do
            {:ok, entry} -> entry_metadata(entry)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.created_ms, :desc)
        |> Enum.take(limit)

      {:error, _} ->
        []
    end
  end

  @doc "Fetch a full rewind checkpoint entry (including messages)."
  def get_rewind_checkpoint(session_id, id) do
    path = Path.join(rewind_session_dir(session_id), sanitize_id(id) <> ".json")

    case read_entry(path) do
      {:ok, entry} -> {:ok, entry}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Restore from a rewind checkpoint.

  `scope` is one of `:code`, `:conversation`, or `:both`.

    * code         — restore touched files to their snapshotted content via
                     the FSCheckpoint shadow repo (`fs_head`).
    * conversation — rewrite the crash-recovery checkpoint with the snapshot's
                     messages (so a resume loads them) and return the messages
                     so a live loop can be updated by the caller.

  Returns `{:ok, result_map}` or `{:error, reason}`.
  """
  def restore_rewind(session_id, id, scope) when scope in [:code, :conversation, :both] do
    case get_rewind_checkpoint(session_id, id) do
      {:ok, entry} ->
        code = if scope in [:code, :both], do: restore_code(entry), else: :skipped

        {convo, messages} =
          if scope in [:conversation, :both],
            do: restore_conversation(entry),
            else: {:skipped, nil}

        {:ok,
         %{
           id: id,
           scope: scope,
           code: code,
           conversation: convo,
           messages: messages,
           iteration: entry[:iteration] || 0,
           plan_mode: entry[:plan_mode] || false,
           turn_count: entry[:turn_count] || 0
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def restore_rewind(_session_id, _id, _scope), do: {:error, :invalid_scope}

  @doc "Delete all rewind checkpoints for a session."
  def clear_rewind_checkpoints(session_id) do
    File.rm_rf(rewind_session_dir(session_id))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Prune oldest rewind checkpoints for a session beyond the retention limit."
  def prune_rewind(session_id, max \\ nil) do
    max = max || max_rewind()
    dir = rewind_session_dir(session_id)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        # Sort by the parsed numeric <millis> prefix (matching
        # list_rewind_checkpoints) rather than lexically — lexical order only
        # matches chronological order while digit-widths are equal and is
        # sensitive to the random suffix, so it could prune a NEWER checkpoint.
        |> Enum.sort_by(&rewind_file_ms/1, :desc)
        |> Enum.drop(max)
        |> Enum.each(fn f -> File.rm(Path.join(dir, f)) end)

        :ok

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ── Rewind private helpers ────────────────────────────────────────────

  defp restore_code(entry) do
    case entry[:fs_head] do
      head when is_binary(head) and head != "" ->
        case OptimalSystemAgent.FSCheckpoint.Server.restore_to(head) do
          {:ok, msg} -> %{status: "restored", detail: msg}
          {:error, reason} -> %{status: "error", detail: reason}
        end

      _ ->
        %{status: "unavailable", detail: "No code snapshot was captured for this checkpoint"}
    end
  end

  defp restore_conversation(entry) do
    messages = entry[:messages] || []

    # Rewrite the crash-recovery checkpoint so a resume of this session loads
    # the restored conversation state.
    #
    # This is a CONVERSATION restore, so it must update only the conversation
    # fields. Going through the full-record writer wrote every field it did not
    # mention as its default — `session_cost_usd` back to $0, the four token
    # counters to 0, and `max_budget_usd` to nil (uncapped) — and then mirrored
    # those zeros into the durable spend sidecar. A user rewinding a $48-of-$50
    # run got a $0, uncapped run back.
    _ =
      update_checkpoint(%{
        session_id: entry[:session_id],
        messages: messages,
        iteration: entry[:iteration] || 0,
        plan_mode: entry[:plan_mode] || false,
        turn_count: entry[:turn_count] || 0
      })

    {%{status: "restored", message_count: length(messages)}, messages}
  end

  defp entry_metadata(entry) do
    %{
      id: entry[:id],
      label: entry[:label] || "",
      created_at: entry[:created_at],
      created_ms: entry[:created_ms] || 0,
      iteration: entry[:iteration] || 0,
      turn_count: entry[:turn_count] || 0,
      message_count: entry[:message_count] || length(entry[:messages] || []),
      has_code: is_binary(entry[:fs_head]) and entry[:fs_head] != ""
    }
  end

  defp read_entry(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, atomize_entry(data)}
    else
      _ -> {:error, :not_found}
    end
  end

  # Convert top-level string keys to atoms and message maps' keys to atoms,
  # mirroring restore_checkpoint/1's handling.
  defp atomize_entry(data) when is_map(data) do
    raw_messages = if is_list(data["messages"]), do: data["messages"], else: []

    messages =
      Enum.map(raw_messages, fn
        msg when is_map(msg) ->
          for {k, v} <- msg, into: %{}, do: {safe_key(k), v}

        other ->
          other
      end)

    %{
      id: data["id"],
      session_id: data["session_id"],
      created_ms: data["created_ms"] || 0,
      created_at: data["created_at"],
      label: data["label"] || "",
      iteration: data["iteration"] || 0,
      plan_mode: data["plan_mode"] || false,
      turn_count: data["turn_count"] || 0,
      message_count: data["message_count"] || length(messages),
      fs_head: data["fs_head"],
      messages: messages
    }
  end

  # Parse the numeric <millis> prefix from a rewind checkpoint filename
  # (`<millis>_<rand>.json`) for chronological ordering. Unparseable names sort
  # oldest (0) so they are pruned first rather than surviving over real points.
  defp rewind_file_ms(filename) do
    case filename |> String.split("_") |> hd() |> Integer.parse() do
      {ms, _} -> ms
      :error -> 0
    end
  end

  defp safe_fs_head do
    OptimalSystemAgent.FSCheckpoint.Server.head()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp sanitize_messages(msgs) when is_list(msgs) do
    Enum.map(msgs, fn
      %{content: c} = m when is_binary(c) -> %{m | content: sanitize_utf8(c)}
      %{"content" => c} = m when is_binary(c) -> %{m | "content" => sanitize_utf8(c)}
      m -> m
    end)
  end

  defp sanitize_messages(_), do: []

  defp derive_label(label) when is_binary(label) do
    label
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @label_max_len)
  end

  defp derive_label(_), do: "checkpoint"

  # Session ids are opaque strings from callers; keep them filesystem-safe.
  defp sanitize_session(session_id) do
    session_id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp sanitize_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.\-=]/, "_")
  end
end
