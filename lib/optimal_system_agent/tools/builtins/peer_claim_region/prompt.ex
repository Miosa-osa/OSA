defmodule OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Prompt do
  @moduledoc """
  Dynamic prompt for `peer_claim_region`.

  References sibling peer tools (`peer_review`, `peer_negotiate_task`) via
  `safe_ref/3` so renaming any of them propagates automatically.
  """

  alias OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    review_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.PeerReview.Constants,
        :tool_name,
        "peer_review"
      )

    negotiate_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.Constants,
        :tool_name,
        "peer_negotiate_task"
      )

    """
    Claim an exclusive line range in a file before editing.

    Prevents concurrent agents from editing the same lines. Always claim
    before editing, release after saving.

    Actions:
    - `claim`   — lock a region (requires `start_line`, `end_line`).
    - `release` — free a claimed region (requires `region_id`).
    - `list`    — see all active claims on a file.
    - `touch`   — reset the #{Constants.claim_ttl_seconds()}s inactivity timer.

    Workflow:
    1. Before editing lines N–M, call with `action: claim`.
    2. You receive a `region_id`. Conflicting claims are rejected immediately.
    3. Call `touch` periodically for long-running edits.
    4. After saving, call with `action: release` + `region_id`.

    Related tools:
    - `#{review_name}` — gate task completion behind a peer review.
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
