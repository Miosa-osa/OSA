defmodule OptimalSystemAgent.Tools.Builtins.PeerReview do
  @moduledoc """
  Peer Review Tool — request or submit a peer review on an artifact.

  Agents use this to gate task completion behind a human-quality review by a
  designated peer. The tool supports two actions:

  - `request` — submit an artifact (file path or inline content) for review
    by a specified reviewer agent or role.
  - `check`   — poll whether a previously submitted artifact has been approved.
  - `submit`  — submit a review verdict (for the reviewer agent).
  """
  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Peer.Review

  @impl true
  def name, do: "peer_review"

  @impl true
  def description do
    "Request or submit a peer review on a work artifact. " <>
      "Use 'request' to submit your work for review before completing a task. " <>
      "Use 'check' to see if a review has been approved. " <>
      "Use 'submit' to post your verdict as the reviewer."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["request", "check", "submit"],
          "description" =>
            "request: submit artifact for review, check: poll review status, submit: post verdict"
        },
        "artifact" => %{
          "type" => "string",
          "description" => "File path or inline content to review (for 'request' action)."
        },
        "reviewer_agent" => %{
          "type" => "string",
          "description" => "Agent ID of the reviewer (for 'request' action)."
        },
        "artifact_id" => %{
          "type" => "string",
          "description" =>
            "Artifact ID returned by a prior 'request' call (for 'check'/'submit')."
        },
        "verdict" => %{
          "type" => "string",
          "enum" => ["approve", "request_changes", "reject"],
          "description" => "Review verdict (for 'submit' action)."
        },
        "comments" => %{
          "type" => "string",
          "description" => "Review comments or summary (for 'submit' action)."
        }
      }
    }
  end

  @impl true
  def safety, do: :write_safe

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  @impl true
  def execute(%{"action" => "request", "artifact" => artifact} = args) do
    from_agent = Map.get(args, "__session_id__", "unknown")
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

  def execute(%{"action" => "check", "artifact_id" => artifact_id}) do
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

  def execute(
        %{"action" => "submit", "artifact_id" => artifact_id, "verdict" => verdict_str} = args
      ) do
    reviewer = Map.get(args, "__session_id__", "unknown")
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

  def execute(%{"action" => "submit"}) do
    {:error, "Missing required parameter: artifact_id and verdict are required for submit."}
  end

  def execute(_) do
    {:error, "Invalid action. Use: request, check, submit"}
  end
end
