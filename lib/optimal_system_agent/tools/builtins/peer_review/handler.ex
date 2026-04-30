defmodule OptimalSystemAgent.Tools.Builtins.PeerReview.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `peer_review`.

  Split mirrors the structured-layout pattern:
    * `validate/2`          — type-check input shape
    * `check_permissions/2` — deny read-only contexts
    * `execute/2`           — dispatch to `OptimalSystemAgent.Peer.Review`
  """

  alias OptimalSystemAgent.Peer.Review
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Validate ─────────────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx)
      when action in ["request", "check", "submit"] do
    {:ok, input}
  end

  def validate(%{"action" => other}, _ctx),
    do: {:error, "Invalid action '#{other}'. Use: request, check, submit", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permissions ──────────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(_input, %UseContext{read_only_request?: true}) do
    {:deny, "Access denied: peer_review is not available in read-only mode"}
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "request", "artifact" => artifact} = args, ctx) do
    from_agent = ctx.session_id || Map.get(args, "__session_id__", "unknown")
    to_agent = Map.get(args, "reviewer_agent", "peer")

    case Review.request_review(from_agent, to_agent, artifact) do
      {:ok, review} ->
        {:ok,
         "Review requested. Artifact ID: `#{review.artifact_id}`.\n" <>
           "Reviewer: #{to_agent}\n" <>
           "Use `peer_review` with action `check` and `artifact_id: #{review.artifact_id}` to poll status."}

      {:error, reason} ->
        {:error, "Failed to request review: #{reason}"}
    end
  end

  def execute(%{"action" => "request"}, _ctx) do
    {:error, "Missing required parameter: artifact is required for 'request' action."}
  end

  def execute(%{"action" => "check", "artifact_id" => artifact_id}, _ctx) do
    case Review.get_review(artifact_id) do
      nil ->
        {:ok, "No review found for artifact `#{artifact_id}`."}

      review ->
        verdict_line =
          if review.verdict do
            "\nVerdict: **#{review.verdict}**" <>
              if(review.summary, do: "\nSummary: #{review.summary}", else: "")
          else
            ""
          end

        {:ok, "Review status for `#{artifact_id}`: **#{review.status}**#{verdict_line}"}
    end
  end

  def execute(%{"action" => "check"}, _ctx) do
    {:error, "Missing required parameter: artifact_id is required for 'check' action."}
  end

  def execute(
        %{"action" => "submit", "artifact_id" => artifact_id, "verdict" => verdict_str} = args,
        ctx
      ) do
    reviewer = ctx.session_id || Map.get(args, "__session_id__", "unknown")
    summary = Map.get(args, "comments")

    verdict =
      case verdict_str do
        "approve" -> :approve
        "request_changes" -> :request_changes
        "reject" -> :reject
        other -> other
      end

    case Review.submit_review(reviewer, artifact_id, %{verdict: verdict, summary: summary}) do
      {:ok, review} ->
        {:ok,
         "Review submitted for artifact `#{artifact_id}`. Verdict: #{review.verdict}. " <>
           "Requesting agent #{review.from_agent} has been notified."}

      {:error, reason} ->
        {:error, "Failed to submit review: #{reason}"}
    end
  end

  def execute(%{"action" => "submit"}, _ctx) do
    {:error,
     "Missing required parameter: artifact_id and verdict are required for 'submit' action."}
  end
end
