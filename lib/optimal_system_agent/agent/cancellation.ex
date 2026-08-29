defmodule OptimalSystemAgent.Agent.Cancellation do
  @moduledoc """
  Shared reader for the cooperative cancel flag.

  `Loop.cancel/1` writes `{session_id, true}` into the `:osa_cancel_flags` ETS
  table (see `Loop.cancel/1` and `ReactLoop.run/1`). Several call sites in the
  loop core and the freeze workstream need to know "is this session cancelled?"
  BEFORE they re-drive work. This module centralises that read so every caller
  observes the flag exactly the way the loop entry check does.
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
end
