defmodule OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.Prompt do
  @moduledoc """
  Dynamic prompt for `peer_negotiate_task`.

  References sibling peer tools (`peer_review`, `peer_claim_region`) via
  `safe_ref/3` so renaming any of them propagates automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    review_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.PeerReview.Constants,
        :tool_name,
        "peer_review"
      )

    claim_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Constants,
        :tool_name,
        "peer_claim_region"
      )

    """
    Contest, redirect, or accept a task assignment.

    Actions:
    - `counter` — suggest a better-suited agent for a task you've been assigned.
    - `accept`  — explicitly accept the assignment (bypass the auto-accept timer).
    - `reject`  — decline the assignment with a reason.
    - `status`  — check the current state of a negotiation.

    Workflow:
    1. Receive a negotiation notification with a `negotiation_id`.
    2. Call with `action: counter` + `counter_agent` + optional `reason` to redirect,
       or `action: accept` to take the task, or `action: reject` to decline.
    3. Call with `action: status` to check where the negotiation stands.

    Related tools:
    - `#{review_name}` — gate task completion behind a peer review.
    - `#{claim_name}` — claim exclusive line ranges before editing.
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
