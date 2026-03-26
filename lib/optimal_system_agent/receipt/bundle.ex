defmodule OptimalSystemAgent.Receipt.Bundle do
  @moduledoc """
  Pure data struct for audit receipt bundles.

  Represents an evidence bundle submitted to the kernel for hash-chained storage.
  Agent submits unsigned bundles; kernel chains and stores them.
  """

  @enforce_keys [:action_type, :action_name, :agent_id, :timestamp]
  defstruct [
    :action_type,
    :action_name,
    :agent_id,
    :timestamp,
    action_id: nil,
    session_id: nil,
    intent_hash: nil,
    duration_ms: 0,
    exit_code: nil,
    result_summary: "",
    evidence: %{},
    sandbox_mode: nil,
    sandbox_image: nil,
    attributable: true,
    legible: true,
    contemporaneous: true,
    original: true,
    accurate: true
  ]

  @doc """
  Build a receipt bundle from tool executor data.
  """
  def from_tool_call(tool_call, post_payload) do
    sandbox = OptimalSystemAgent.Sandbox.Config.from_config()
    args = tool_call.arguments || %{}
    session_id = post_payload[:session_id] || post_payload["session_id"]

    intent_hash =
      :crypto.hash(:sha256, "#{tool_call.name}:#{Jason.encode!(args)}:#{session_id}")
      |> Base.encode16(case: :lower)

    %__MODULE__{
      action_type: "tool_call",
      action_name: tool_call.name,
      agent_id: Application.get_env(:optimal_system_agent, :agent_id, "osa-agent"),
      timestamp: DateTime.utc_now(),
      action_id: Map.get(tool_call, :id),
      session_id: session_id,
      intent_hash: intent_hash,
      duration_ms: post_payload[:duration_ms] || post_payload["duration_ms"] || 0,
      result_summary: String.slice(to_string(post_payload[:result] || post_payload["result"] || ""), 0, 500),
      evidence: args,
      sandbox_mode: if(sandbox.enabled, do: Atom.to_string(sandbox.mode)),
      sandbox_image: if(sandbox.enabled, do: sandbox.image)
    }
  end

  @doc """
  Build a receipt bundle from investigation VAOS_JSON metadata.
  """
  def from_investigation(json_metadata) do
    claim_id = json_metadata[:claim_id] || json_metadata["claim_id"]
    topic = json_metadata[:topic] || json_metadata["topic"]
    session_id = json_metadata[:session_id] || json_metadata["session_id"]

    intent_hash =
      :crypto.hash(:sha256, "investigate:#{Jason.encode!(json_metadata)}:#{session_id}")
      |> Base.encode16(case: :lower)

    %__MODULE__{
      action_type: "investigation",
      action_name: "investigate",
      agent_id: Application.get_env(:optimal_system_agent, :agent_id, "osa-agent"),
      timestamp: DateTime.utc_now(),
      action_id: claim_id,
      session_id: session_id,
      intent_hash: intent_hash,
      evidence: %{
        topic: topic,
        claim_id: claim_id,
        direction: json_metadata[:direction] || json_metadata["direction"],
        for_score: json_metadata[:for_score] || json_metadata["for_score"],
        against_score: json_metadata[:against_score] || json_metadata["against_score"],
        grounded_for_score: json_metadata[:grounded_for_score] || json_metadata["grounded_for_score"],
        grounded_against_score: json_metadata[:grounded_against_score] || json_metadata["grounded_against_score"],
        papers_found: json_metadata[:papers_found] || json_metadata["papers_found"],
        source_counts: json_metadata[:source_counts] || json_metadata["source_counts"],
        uncertainty: json_metadata[:uncertainty] || json_metadata["uncertainty"],
        belief: json_metadata[:belief] || json_metadata["belief"],
        fraudulent_citations: json_metadata[:fraudulent_citations] || json_metadata["fraudulent_citations"]
      }
    }
  end

  @doc """
  Convert bundle to the map shape expected by `GrpcClient.confirm_audit/1`.
  """
  def to_audit_map(%__MODULE__{} = b) do
    %{
      agent_id: b.agent_id,
      action_id: b.action_id || "unknown",
      intent_hash: b.intent_hash || "",
      jwt_token: "",
      attributable: b.attributable,
      legible: b.legible,
      contemporaneous: b.contemporaneous,
      original: b.original,
      accurate: b.accurate,
      performed_at: DateTime.to_unix(b.timestamp),
      performed_by: b.agent_id,
      method: b.action_type,
      context: %{
        "action_name" => b.action_name,
        "session_id" => b.session_id || "",
        "duration_ms" => to_string(b.duration_ms),
        "result_summary" => b.result_summary || "",
        "evidence_json" => Jason.encode!(b.evidence || %{}),
        "sandbox_mode" => b.sandbox_mode || "",
        "sandbox_image" => b.sandbox_image || ""
      }
    }
  end
end
