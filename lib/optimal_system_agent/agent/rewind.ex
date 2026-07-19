defmodule OptimalSystemAgent.Agent.Rewind do
  @moduledoc """
  Unified `/rewind` coordinator — CC/opencode parity.

  Composes the two pieces OSA already had separately:

    * `OptimalSystemAgent.FSCheckpoint.Server` — shadow-git file restore
    * `OptimalSystemAgent.Agent.Loop.Checkpoint` — per-prompt conversation
      snapshot + restore (`create_rewind_checkpoint/2`, `restore_rewind/3`)

  into one atomic "go back to turn N" operation that also supports undoing
  the undo (`unrevert/1`) and reporting what changed (`diff_summary/2`),
  mirroring opencode `session/revert.ts` (`revert` / `unrevert` / diff
  additions+deletions+files) and CC `fileHistory.ts` per-message snapshots.

  ## Atomicity model

  `rewind_to/3` first takes a fresh checkpoint of the CURRENT state (files +
  messages) — the "undo point" — before restoring the target checkpoint. The
  undo point's id is recorded in a small per-session pointer file so a later
  `unrevert/1` can restore straight back to it. Only the single most recent
  rewind can be undone (matching opencode: `unrevert` clears the revert
  state after restoring), which keeps the model simple and predictable.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.FSCheckpoint.Server, as: FSCheckpoint

  @doc """
  Rewind `session_id` to the state captured by rewind checkpoint
  `checkpoint_id`.

  `scope` is `:code`, `:conversation`, or `:both` (default `:both`), same as
  `Checkpoint.restore_rewind/3`.

  Returns `{:ok, result}` where `result` has:

    * `:id`          — the checkpoint id that was restored to
    * `:scope`       — the scope that was applied
    * `:code`        — code-restore result map (or `:skipped`)
    * `:conversation`— conversation-restore result map (or `:skipped`)
    * `:messages`    — the restored messages (or `nil`)
    * `:diff`        — `%{additions:, deletions:, files:, paths:, messages: %{...}}`
                       computed BEFORE restoring (what this rewind is about to undo)
    * `:undo_id`      — the id of the pre-rewind snapshot; pass to `unrevert/1`
                       implicitly (unrevert reads it back from the pointer file)

  Never disrupts a live loop: if messages were restored, they are pushed into
  the running `Loop` process (best-effort, matches existing wiring in
  `RewindRoutes`).
  """
  @spec rewind_to(String.t(), String.t(), :code | :conversation | :both) ::
          {:ok, map()} | {:error, term()}
  def rewind_to(session_id, checkpoint_id, scope \\ :both) do
    with {:ok, _target} <- Checkpoint.get_rewind_checkpoint(session_id, checkpoint_id) do
      diff = diff_summary(session_id, checkpoint_id)

      undo_id =
        case snapshot_current_state(session_id, "pre-rewind snapshot (undo of #{checkpoint_id})") do
          {:ok, id} -> id
          {:error, _} -> nil
        end

      case Checkpoint.restore_rewind(session_id, checkpoint_id, scope) do
        {:ok, result} ->
          apply_to_live_loop(session_id, result)

          if undo_id do
            record_last_rewind(session_id, %{undo_id: undo_id, target_id: checkpoint_id, scope: scope})
          end

          {:ok, Map.merge(result, %{diff: diff, undo_id: undo_id})}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Undo the most recent `rewind_to/3` for `session_id` — restores files and
  messages forward to the state that existed right before that rewind.

  Returns `{:ok, result}` (same shape as `rewind_to/3`'s result, without
  `:diff`/`:undo_id`) or `{:error, :no_rewind_to_undo}` when there is nothing
  to undo (either no rewind has happened yet, or it was already undone).
  """
  @spec unrevert(String.t()) :: {:ok, map()} | {:error, term()}
  def unrevert(session_id) do
    case read_last_rewind(session_id) do
      {:ok, %{"undo_id" => undo_id}} when is_binary(undo_id) ->
        case Checkpoint.restore_rewind(session_id, undo_id, :both) do
          {:ok, result} ->
            apply_to_live_loop(session_id, result)
            clear_last_rewind(session_id)
            {:ok, result}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :no_rewind_to_undo}
    end
  end

  @doc """
  Report whether `session_id` currently has an undo-able rewind, and its
  target/undo checkpoint ids. Used by the TUI to decide whether to show an
  "undo rewind" affordance.
  """
  @spec last_rewind(String.t()) :: {:ok, map()} | {:error, :none}
  def last_rewind(session_id) do
    case read_last_rewind(session_id) do
      {:ok, data} -> {:ok, atomize_pointer(data)}
      _ -> {:error, :none}
    end
  end

  @doc """
  Compute a diff summary between the CURRENT state and the state captured by
  rewind checkpoint `checkpoint_id`, mirroring opencode `revert.ts`'s
  `diffs.reduce(additions/deletions/files)`.

  Returns a map:

    * `:additions`, `:deletions`, `:files`, `:paths` — file-content diff via
      the shadow-git repo (`FSCheckpoint.diff_stat/2`); zeroed out when the
      checkpoint captured no code snapshot (`fs_head` is nil).
    * `:messages` — `%{current_count:, target_count:, removed:}` — how many
      trailing messages would be truncated by restoring to this point.
  """
  @spec diff_summary(String.t(), String.t()) :: map()
  def diff_summary(session_id, checkpoint_id) do
    case Checkpoint.get_rewind_checkpoint(session_id, checkpoint_id) do
      {:ok, target} ->
        file_diff = file_diff_against_current(target)
        message_diff = message_diff_against_current(session_id, target)
        Map.merge(file_diff, %{messages: message_diff})

      {:error, _} ->
        empty_diff()
    end
  end

  # ── Private: file diff ────────────────────────────────────────────────

  defp file_diff_against_current(target) do
    case target[:fs_head] do
      head when is_binary(head) and head != "" ->
        current_head = safe_current_head()

        case FSCheckpoint.diff_stat(head, current_head || "HEAD") do
          {:ok, stat} -> stat
          {:error, _} -> %{additions: 0, deletions: 0, files: 0, paths: []}
        end

      _ ->
        %{additions: 0, deletions: 0, files: 0, paths: []}
    end
  end

  defp safe_current_head do
    FSCheckpoint.head()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # ── Private: message diff ─────────────────────────────────────────────

  defp message_diff_against_current(session_id, target) do
    current_count = current_message_count(session_id)
    target_count = target[:message_count] || length(target[:messages] || [])

    %{
      current_count: current_count,
      target_count: target_count,
      removed: max(current_count - target_count, 0)
    }
  end

  # Uses the same "current state" resolution as the undo snapshot (live loop
  # messages when a loop is running, else the crash-recovery checkpoint) so
  # the reported diff matches what an actual rewind would truncate.
  defp current_message_count(session_id) do
    session_id
    |> current_state()
    |> Map.get(:messages, [])
    |> length()
  end

  defp empty_diff do
    %{additions: 0, deletions: 0, files: 0, paths: [], messages: %{current_count: 0, target_count: 0, removed: 0}}
  end

  # ── Private: current-state snapshot (for the undo point) ─────────────

  defp snapshot_current_state(session_id, label) do
    Checkpoint.create_rewind_checkpoint(current_state(session_id), label: label)
  end

  # Best-effort reconstruction of "current loop state" from public,
  # read-only Loop/Checkpoint APIs. Prefers the live loop's messages (freshest)
  # and falls back to the crash-recovery checkpoint for iteration/plan_mode/
  # turn_count, which is written after every completed tool cycle.
  defp current_state(session_id) do
    base = Checkpoint.restore_checkpoint(session_id)
    live_messages = safe_get_messages(session_id)

    messages =
      case live_messages do
        [_ | _] = msgs -> msgs
        _ -> Map.get(base, :messages, [])
      end

    %{
      session_id: session_id,
      messages: messages,
      iteration: Map.get(base, :iteration, 0),
      plan_mode: Map.get(base, :plan_mode, false),
      turn_count: Map.get(base, :turn_count, 0)
    }
  end

  defp safe_get_messages(session_id) do
    Loop.get_messages(session_id)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # ── Private: apply restored conversation to a live loop ──────────────

  defp apply_to_live_loop(session_id, %{messages: messages} = result) when is_list(messages) do
    Loop.rewind_conversation(session_id, messages, %{
      iteration: result[:iteration] || 0,
      plan_mode: result[:plan_mode] || false,
      turn_count: result[:turn_count] || 0
    })
  end

  defp apply_to_live_loop(_session_id, _result), do: :ok

  # ── Private: "last rewind" pointer (enables unrevert) ─────────────────

  defp pointer_path(session_id) do
    Path.join(Checkpoint.rewind_dir(), sanitize_session(session_id) <> ".undo.json")
  end

  defp record_last_rewind(session_id, %{undo_id: undo_id, target_id: target_id, scope: scope}) do
    data = %{
      undo_id: undo_id,
      target_id: target_id,
      scope: to_string(scope),
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    path = pointer_path(session_id)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, Jason.encode!(data), [:utf8])
    File.rename!(tmp, path)
    :ok
  rescue
    e ->
      Logger.warning("[rewind] Failed to record undo pointer: #{Exception.message(e)}")
      :ok
  end

  defp read_last_rewind(session_id) do
    path = pointer_path(session_id)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp clear_last_rewind(session_id) do
    File.rm(pointer_path(session_id))
    :ok
  rescue
    _ -> :ok
  end

  defp atomize_pointer(data) do
    %{
      undo_id: data["undo_id"],
      target_id: data["target_id"],
      scope: data["scope"],
      recorded_at: data["recorded_at"]
    }
  end

  # Mirrors Checkpoint's session-id sanitization so the pointer file is a
  # sibling of that session's rewind checkpoint directory.
  defp sanitize_session(session_id) do
    session_id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end
end
