defmodule OptimalSystemAgent.Tools.Builtins.PeerReview.Prompt do
  @moduledoc """
  Dynamic prompt for `peer_review`.

  References sibling peer tools (`peer_claim_region`, `peer_negotiate_task`)
  via `safe_ref/3` so renaming any of them propagates automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    claim_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Constants,
        :tool_name,
        "peer_claim_region"
      )

    negotiate_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.Constants,
        :tool_name,
        "peer_negotiate_task"
      )

    """
    Request or submit a peer review on a work artifact.

    Actions:
    - `request` — submit your work for review before completing a task.
    - `check`   — poll whether a previously submitted artifact has been approved.
    - `submit`  — post your verdict as the reviewer.

    Workflow:
    1. Before finishing a task, call with `action: request` and provide the artifact.
    2. The reviewer agent is notified. You receive an `artifact_id`.
    3. Call with `action: check` + `artifact_id` until the verdict is in.
    4. The reviewer calls with `action: submit` + their verdict.

    Related tools:
    - `#{claim_name}` — claim exclusive line ranges before editing.
    - `#{negotiate_name}` — contest or redirect a task assignment.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
