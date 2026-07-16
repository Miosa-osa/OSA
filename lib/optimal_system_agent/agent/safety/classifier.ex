defmodule OptimalSystemAgent.Agent.Safety.Classifier do
  @moduledoc """
  POLICY (pure): classify a single tool call into a `Verdict`.

  The classifier is the only place that knows how to turn `(tool_name, args,
  ctx)` into a risk assessment. It:

    1. Extracts the primary argument using the same precedence as
       `OptimalSystemAgent.Permissions.matches_pattern?/2`
       (`command || path || query || task || first value`).
    2. Runs the pure regex tables in `Rules` for the five command-shaped
       categories and the allowlist-driven `untrusted_network` category.
    3. Delegates the `prompt_injection_driven` category to the pure
       `PromptInjection.prompt_injection?/1` detector.
    4. Returns the single **highest-risk** `Verdict`.

  It has **no side effects**: no ETS, no logging, no Bus emits, no config reads
  beyond what is passed in `ctx`. Enforcement (counters, pause, events) is the
  job of `Guardian`.
  """

  alias OptimalSystemAgent.Agent.Safety.{PromptInjection, Rules, Verdict}

  @type ctx :: %{optional(atom()) => any()}

  # Risk assigned to each category when its rules match.
  @category_risk %{
    privilege_escalation: :dangerous,
    force_push: :dangerous,
    prod_deploy: :dangerous,
    secret_exfiltration: :dangerous,
    mass_delete: :dangerous,
    untrusted_network: :caution,
    prompt_injection_driven: :dangerous
  }

  @doc """
  Classify a tool call. Returns the highest-risk `Verdict`.

  `ctx` may carry `:untrusted_host_allowlist` (list of trusted hosts). When
  absent, the network check treats every explicit host as untrusted (caution).
  """
  @spec classify(String.t(), map(), ctx()) :: Verdict.t()
  def classify(tool_name, args, ctx \\ %{}) do
    primary = primary_arg(args)
    allowlist = Map.get(ctx, :untrusted_host_allowlist, [])

    []
    |> maybe_add(regex_verdict(primary, tool_name))
    |> maybe_add(network_verdict(primary, allowlist, tool_name))
    |> maybe_add(injection_verdict(primary, args, tool_name))
    |> highest(tool_name)
  end

  # ── primary argument extraction (mirrors Permissions.matches_pattern?/2) ──

  @doc """
  Extract the primary string argument from a tool-call args map, using the same
  precedence as `Permissions.matches_pattern?/2`:
  `command || path || query || task || first value`.
  """
  @spec primary_arg(map() | any()) :: String.t() | nil
  def primary_arg(args) when is_map(args) do
    primary =
      Map.get(args, "command") ||
        Map.get(args, "path") ||
        Map.get(args, "query") ||
        Map.get(args, "task") ||
        args |> Map.values() |> List.first()

    if is_binary(primary), do: primary, else: nil
  end

  def primary_arg(_), do: nil

  # ── per-category verdict builders ────────────────────────────────────

  defp regex_verdict(nil, _tool), do: nil

  defp regex_verdict(text, tool) do
    case Rules.first_match(text) do
      {category, label} -> verdict(category, label, tool)
      nil -> nil
    end
  end

  defp network_verdict(nil, _allowlist, _tool), do: nil

  defp network_verdict(text, allowlist, tool) do
    case Rules.network_match(text, allowlist) do
      {:untrusted_network, host} ->
        verdict(:untrusted_network, "untrusted host: #{host}", tool)

      nil ->
        nil
    end
  end

  # Prompt-injection is delegated to the pure three-tier detector. We scan
  # the primary arg and, defensively, any string values in the args map.
  defp injection_verdict(primary, args, tool) do
    candidates =
      [primary | string_values(args)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if Enum.any?(candidates, &PromptInjection.prompt_injection?/1) do
      verdict(:prompt_injection_driven, "prompt-injection pattern in tool argument", tool)
    else
      nil
    end
  end

  defp string_values(args) when is_map(args) do
    args |> Map.values() |> Enum.filter(&is_binary/1)
  end

  defp string_values(_), do: []

  # ── verdict assembly ─────────────────────────────────────────────────

  defp verdict(category, label, tool) do
    risk = Map.fetch!(@category_risk, category)

    %Verdict{
      risk: risk,
      category: category,
      matched_rule: label,
      reason: reason_for(category, label),
      tool: tool
    }
  end

  defp reason_for(:privilege_escalation, label),
    do: "privilege escalation detected (#{label})"

  defp reason_for(:force_push, label), do: "destructive git operation detected (#{label})"
  defp reason_for(:prod_deploy, label), do: "production deploy/infra mutation detected (#{label})"

  defp reason_for(:secret_exfiltration, label),
    do: "possible secret exfiltration detected (#{label})"

  defp reason_for(:mass_delete, label), do: "mass-deletion / destructive operation detected (#{label})"
  defp reason_for(:untrusted_network, label), do: "network call to #{label}"

  defp reason_for(:prompt_injection_driven, label),
    do: "action appears driven by prompt injection (#{label})"

  defp reason_for(_category, label), do: label

  # ── highest-risk selection ───────────────────────────────────────────

  defp maybe_add(list, nil), do: list
  defp maybe_add(list, %Verdict{} = v), do: [v | list]

  defp highest([], tool), do: Verdict.safe(tool)

  defp highest(verdicts, _tool) do
    Enum.max_by(verdicts, &Verdict.severity/1)
  end
end
