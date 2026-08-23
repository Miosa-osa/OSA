defmodule OptimalSystemAgent.Security.FindingSkeptic do
  @moduledoc """
  Independent-validator gate for pentest findings.

  Parent-run tools are not independent. A finding is report-confirmed only
  when a `security_validation` child reproduced it and left a receipt.
  Pure functions: no LLM calls, no agent spawn.

  Mirrors ReportGate: collect every missing piece, never guess.
  """

  @confirmed [:confirmed, "confirmed"]
  @completed [:completed, "completed"]
  @unconfirmed [:rejected, :inconclusive, :timeout, :failed, :canceled, nil]

  @info_categories [:info, :recon, :finding, "info", "recon", "finding"]

  @reason_validator "missing independent validator (spawn security_validation)"
  @reason_verdict "validation did not confirm"
  @reason_receipt "missing receipt (poc, evidence_path, or evidence_id)"

  @doc """
  True when an independent `security_validation` child confirmed the finding
  and left a receipt. Parent self-confirm (`status: :confirmed` with no
  `validator_id`) is false.
  """
  @spec independent?(map()) :: boolean()
  def independent?(finding) when is_map(finding) do
    reasons(finding) == []
  end

  def independent?(_), do: false

  @doc """
  Promote a finding to report-confirmed status when `independent?/1`.

  On success, `:status` is set to `:confirmed` (atom key). On failure,
  returns every missing piece so the caller can spawn a validator rather
  than guess.
  """
  @spec promote(map()) :: {:ok, map()} | {:error, [String.t()]}
  def promote(finding) when is_map(finding) do
    case reasons(finding) do
      [] -> {:ok, put_status(finding, :confirmed)}
      reasons -> {:error, reasons}
    end
  end

  def promote(_), do: {:error, ["finding must be a map"]}

  @doc """
  True for vulnerability-class findings. False for info, recon, and
  finding-category recon notes. Also accepts a category atom.
  """
  @spec required?(map() | atom()) :: boolean()
  def required?(category) when is_atom(category) or is_binary(category) do
    normalize_category(category) == :vulnerability
  end

  def required?(finding) when is_map(finding) do
    present?(field(finding, :vuln_class)) or
      normalize_category(field(finding, :category)) == :vulnerability
  end

  def required?(_), do: false

  @doc """
  `create_agent` arguments for a `security_validation` child. No side effects.
  """
  @spec spawn_spec(map()) :: map()
  def spawn_spec(finding) when is_map(finding) do
    class = stringify(field(finding, :vuln_class)) || "finding"
    target = stringify(field(finding, :target))

    %{
      profile: "security_validation",
      name: "validate-" <> compact_label(class, target),
      prompt: spawn_prompt(class, target),
      success_criteria: "independent reproduction or a reasoned reject citing the receipt"
    }
  end

  def spawn_spec(_), do: spawn_spec(%{})

  defp reasons(finding) do
    []
    |> maybe_add(not validator?(finding), @reason_validator)
    |> maybe_add(not confirmed?(finding), @reason_verdict)
    |> maybe_add(not receipt?(finding), @reason_receipt)
  end

  defp validator?(finding) do
    case field(finding, :validator_id) do
      id when is_binary(id) -> present?(id)
      _ -> false
    end
  end

  defp confirmed?(finding) do
    verdict = field(finding, :validation_verdict)
    status = field(finding, :validation_status)

    verdict in @confirmed and verdict not in @unconfirmed and
      acceptable_status?(status, verdict, validator?(finding))
  end

  defp acceptable_status?(status, verdict, has_validator) do
    cond do
      status in @completed -> true
      is_nil(status) and verdict in @confirmed and has_validator -> true
      true -> false
    end
  end

  defp receipt?(finding) do
    present?(field(finding, :poc)) or present?(field(finding, :evidence_path)) or
      present?(field(finding, :evidence_id))
  end

  defp put_status(finding, status) do
    finding
    |> Map.delete("status")
    |> Map.put(:status, status)
  end

  defp spawn_prompt(class, target) do
    where = if target, do: " against #{target}", else: ""

    "Reproduce #{class} independently#{where}, " <>
      "do not trust the parent conclusion. " <>
      "Return verdict confirmed|rejected|inconclusive with a tool receipt."
  end

  defp compact_label(class, target) do
    [class, target]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&slug/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("-")
    |> case do
      "" -> "finding"
      name -> name
    end
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/^https?:\/\//, "")
    |> String.replace(~r/[^a-z0-9.]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 32)
  end

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v), do: to_string(v)

  defp normalize_category(cat) when cat in @info_categories, do: :info
  defp normalize_category(:vulnerability), do: :vulnerability
  defp normalize_category("vulnerability"), do: :vulnerability
  defp normalize_category(_), do: nil

  defp field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: true

  defp maybe_add(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add(reasons, false, _), do: reasons
end
