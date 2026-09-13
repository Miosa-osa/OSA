defmodule OptimalSystemAgent.Agent.StepRevert do
  @moduledoc """
  Restore the worktree to N file-mutating steps ago.

  Pre-tool snapshots already live in `FSCheckpoint` (shadow git at
  `~/.osa/fs_checkpoints`, commit message `tool | session | paths`).
  `/rewind` restores a **user-turn** checkpoint (conversation + code).
  This module is the OpenCode `session/revert.ts` analog: `/revert N`
  restores the files as they were before the last N mutating tools, and
  leaves the transcript (`updates.jsonl`) alone.
  """

  alias OptimalSystemAgent.FSCheckpoint.Server, as: FSCheckpoint

  @type result :: %{
          steps: pos_integer(),
          checkpoint_id: String.t(),
          tool: String.t() | nil,
          files: String.t() | nil
        }

  @doc """
  Restore files for `session_id` to N checkpoints ago (1 = last mutating tool).

  Transcript is not touched.
  """
  @spec revert(String.t(), pos_integer()) :: {:ok, result()} | {:error, term()}
  def revert(session_id, n) when is_binary(session_id) and is_integer(n) and n >= 1 do
    with {:ok, entries} <- session_checkpoints(session_id),
         {:ok, entry} <- nth(entries, n) do
      case FSCheckpoint.restore(entry.id) do
        {:ok, _} ->
          {:ok,
           %{
             steps: n,
             checkpoint_id: entry.id,
             tool: Map.get(entry, :tool),
             files: Map.get(entry, :files)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def revert(_session_id, n) when is_integer(n) and n < 1, do: {:error, :invalid_steps}
  def revert(_, _), do: {:error, :invalid_args}

  @doc "Checkpoints for this session, newest first."
  @spec session_checkpoints(String.t()) :: {:ok, [map()]} | {:error, term()}
  def session_checkpoints(session_id) when is_binary(session_id) do
    case FSCheckpoint.list_checkpoints(200) do
      {:ok, entries} ->
        {:ok, Enum.filter(entries, &session_match?(&1, session_id))}

      other ->
        other
    end
  end

  defp nth(entries, n) do
    case Enum.at(entries, n - 1) do
      nil -> {:error, :not_enough_checkpoints}
      entry -> {:ok, entry}
    end
  end

  defp session_match?(entry, session_id) do
    sid = Map.get(entry, :session_id)

    cond do
      is_binary(sid) and sid == session_id ->
        true

      is_binary(Map.get(entry, :files)) and String.contains?(entry.files || "", session_id) ->
        true

      is_binary(Map.get(entry, :tool)) ->
        # Commit subject is `tool | session | paths`. parse_log_line currently
        # stores first part as `:tool` and last as `:files`, dropping the
        # middle. Recover it from either field when present.
        String.contains?(to_string(entry.tool), session_id)

      true ->
        false
    end
  end
end
