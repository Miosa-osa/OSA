defmodule OptimalSystemAgent.Agent.Cancellation do
  @moduledoc """
  Shared reader for the cooperative cancel flag.

  `Loop.cancel/1` writes `{session_id, true}` into the `:osa_cancel_flags` ETS
  table (see `Loop.cancel/1` and `ReactLoop.run/1`). Several call sites in the
  loop core and the freeze workstream need to know "is this session cancelled?"
  BEFORE they re-drive work. This module centralises that read so every caller
  observes the flag exactly the way the loop entry check does.

  ## Per-tool cancel (WS-B)

  The session-wide flag is coarse: one interrupt cancels EVERY parallel tool in
  flight. Borrowed from Codex's per-EXEC `CancellationToken`, this module also
  supports a per-tool key `{session_id, tool_call_id}` in the SAME table, so a
  targeted cancel can drop ONE wedged call while its siblings finish.
  `cancelled?/2` is the reader honoured by the tool orchestrator: it returns
  true when EITHER the session-wide flag OR the per-tool flag is set. The
  per-tool key is a 2-tuple, so it never collides with a bare `session_id` key,
  and the binary-guarded folds in `Loop.cancel/1`/`Loop.clear_cancel/1` skip it.
  """

  # Same table name and key/value shape the loop's own cancel check reads
  # (`ReactLoop.run/1` around the `:ets.lookup(@cancel_table, sid)` clause).
  @cancel_table :osa_cancel_flags

  @doc """
  True when the cooperative cancel flag is set for `session_id`.

  `cancelled?(nil)` returns false. A missing ETS table (agent not running)
  also returns false rather than raising.
  """
  @spec cancelled?(String.t() | nil) :: boolean()
  def cancelled?(nil), do: false

  def cancelled?(session_id) do
    case :ets.lookup(@cancel_table, session_id) do
      [{^session_id, true}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  True when EITHER the session-wide flag OR the per-tool flag for
  `{session_id, tool_call_id}` is set.

  This is the per-tool-aware reader. `cancelled?/1` semantics are unchanged and
  still answer the session-wide question; this arity only ADDS the per-tool
  check on top of it. A `nil` session or `nil` tool id degrades gracefully to
  the session-wide answer.
  """
  @spec cancelled?(String.t() | nil, term()) :: boolean()
  def cancelled?(session_id, tool_call_id) do
    cancelled?(session_id) or tool_cancelled?(session_id, tool_call_id)
  end

  @doc """
  Set the per-tool cancel flag for `{session_id, tool_call_id}`.

  Drops ONE in-flight tool call without touching the session-wide flag, so its
  siblings keep running. No-op (rather than raising) when the id is missing or
  the ETS table is not up (agent not running).
  """
  @spec cancel_tool(String.t(), term()) :: :ok
  def cancel_tool(session_id, tool_call_id)
      when is_binary(session_id) and not is_nil(tool_call_id) do
    :ets.insert(@cancel_table, {{session_id, tool_call_id}, true})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def cancel_tool(_session_id, _tool_call_id), do: :ok

  @doc """
  Clear a per-tool cancel flag. Symmetric with `cancel_tool/2` so a targeted
  cancel can be undone without disturbing the session-wide flag.
  """
  @spec clear_tool(String.t(), term()) :: :ok
  def clear_tool(session_id, tool_call_id) when is_binary(session_id) do
    :ets.delete(@cancel_table, {session_id, tool_call_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear_tool(_session_id, _tool_call_id), do: :ok

  # Per-tool read only - `cancelled?/2` already OR's in the session-wide flag.
  defp tool_cancelled?(_session_id, nil), do: false

  defp tool_cancelled?(session_id, tool_call_id) do
    key = {session_id, tool_call_id}

    case :ets.lookup(@cancel_table, key) do
      [{^key, true}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end
end
