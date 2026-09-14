defmodule OptimalSystemAgent.Agent.DefenseContext do
  @moduledoc "Routes defensive requests to the bounded lab and defense skill library."

  @phrases [
    "cyber defense",
    "cyber defence",
    "blue team",
    "blue-team",
    "attack simulation",
    "simulate an attack",
    "simulate attacks",
    "simulate targets",
    "detection engineering",
    "incident response",
    "threat hunting",
    "endpoint hardening",
    "sandbox triage",
    "vulnerability management",
    "siem",
    "network defense",
    "network defence",
    "email security",
    "threat modeling",
    "threat modelling"
  ]

  @doc "Returns compact discovery guidance for recent user defense requests."
  def block(state) when is_map(state) do
    text =
      state
      |> Map.get(:messages, [])
      |> normalize_messages()
      |> Enum.filter(&user_message?/1)
      |> Enum.take(-3)
      |> Enum.map_join(" ", &message_text/1)
      |> String.downcase()

    if Enum.any?(@phrases, &String.contains?(text, &1)) do
      """
      <cyber_defense>
      For defensive work, discover `cyber_defense` via tool_search. `scenarios` lists
      the supported lab exercises; `run` executes baseline, bounded simulation,
      detection evaluation, lab remediation and retest, and returns evidence.
      Read attack-simulation for the exact arguments. This lab tests bundled toy
      targets only: its result does not certify a real deployment or run malware.
      For real systems, select the relevant defense skill, inspect actual evidence,
      and propose changes with rollback and independent verification. A detection
      alert is not proof an attack was prevented; a proposed patch is not a verified fix.
      Skills: attack-simulation, detection-engineering, incident-response,
      threat-hunting, log-analysis, network-defense, email-security,
      endpoint-hardening, vulnerability-management, sandbox-triage,
      siem-operations, threat-modeling. Load their bodies with skill_view.
      </cyber_defense>
      """
    end
  end

  def block(_), do: nil

  defp normalize_messages(messages) when is_list(messages), do: messages
  defp normalize_messages(_), do: []

  defp user_message?(%{role: role}), do: role in [:user, "user"]
  defp user_message?(%{"role" => role}), do: role in [:user, "user"]
  defp user_message?(_), do: false

  defp message_text(message) do
    case Map.get(message, :content, Map.get(message, "content", "")) do
      text when is_binary(text) -> text
      parts when is_list(parts) -> Enum.map_join(parts, " ", &part_text/1)
      _ -> ""
    end
  end

  defp part_text(%{type: "text", text: text}) when is_binary(text), do: text
  defp part_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp part_text(_), do: ""
end
