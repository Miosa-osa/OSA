defmodule OptimalSystemAgent.Speculative.Tools.StartSpeculative.Prompt do
  @moduledoc """
  Dynamic prompt for `start_speculative`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Begin speculative execution — work ahead on a predicted next task.

    Returns a `speculative_id` immediately. The agent performs anticipated
    work (file writes, decisions, message drafts) while the real task is
    still arriving. When the actual task arrives:

    - If it matches and assumptions hold: call `promote` to apply the work
    - If it doesn't match or assumptions broke: call `discard` to clean up

    Use to eliminate re-work latency when the next task is highly predictable.
    Always provide explicit, falsifiable assumptions — vague assumptions make
    promotion unreliable.
    """
  end
end
