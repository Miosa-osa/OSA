defmodule OptimalSystemAgent.Agent.Safety.ModelClassifier do
  @moduledoc """
  OPTIONAL model-based risk classifier for auto-mode (Claude Code parity, #34).

  This complements — never replaces — the pure rule-based path
  (`Rules` → `Classifier` → `Guardian`). It scores a single proposed tool call
  into a `Verdict` (`:safe` / `:caution` / `:dangerous`) using a three-stage
  strategy:

    1. **Rules fast-path (obvious cases).** Run the existing pure `Classifier`.
       If it already found a `:dangerous` verdict, return it verbatim — the model
       cannot make an obviously-dangerous call safe. If the call is obviously
       benign (no command-shaped / mutating surface and nothing matched), return
       the safe rule verdict — no model call needed.

    2. **Model assessment (ambiguous cases).** For everything in between — a
       command/mutation surface the rules did not flag, or a `:caution` the model
       might escalate — ask the LLM a cheap classification prompt that returns a
       one-line risk tier + reason. The model's verdict is combined with the rule
       verdict by **taking the higher risk** (the model can only escalate, never
       downgrade below the rules).

    3. **Heuristic fallback.** When the classifier is disabled, no budget remains,
       the model errors, or no provider is reachable, a pure keyword/regex
       heuristic produces the assessment instead. This keeps the feature fully
       functional (and deterministic) with no model available.

  ## Purity / side effects

  This module is *policy*, like `Classifier`: it performs no ETS writes, no event
  emission and no transcript writes. Enforcement (counters, pause, events,
  transcript) remains the job of `Guardian`. The only impurity is the optional
  outbound LLM call in stage 2, which is fully isolated, rescued, and skipped
  entirely when the classifier is disabled (the default).

  ## Configuration

      config :optimal_system_agent, :auto_mode,
        model_classifier: [
          enabled: false,   # OFF by default — rule-based behavior unchanged
          provider: nil,    # nil → registry default provider
          model: nil,       # nil → provider default model
          max_tokens: 128
        ]

  ## Testing hook

  `classify/2` accepts an optional `ctx[:assessor]` — a `(name, args -> Verdict.t
  | nil)` function used in place of the live model call for the ambiguous branch.
  This makes the combine/escalation logic deterministically testable without a
  network round-trip.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Safety.{Classifier, Verdict}
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  # Tool names whose effects are worth a model second-opinion even when the
  # rules found nothing: they execute commands or mutate the workspace/system.
  @review_tools ~w(
    shell_execute shell run_command bash code_sandbox repl
    file_write file_edit multi_file_edit file_create file_delete file_move
    git download
  )

  # ── heuristic tables (pure fallback) ────────────────────────────────
  # These catch a few risky shapes the rule tables intentionally leave to the
  # model. Kept small and conservative — the hard/irreversible cases already
  # live in `Rules` / `DangerousCommands`.
  @heuristic_dangerous [
    {~r/\brm\b[^\n]*\s-\w*r/i, "recursive delete"},
    {~r/\bgit\s+reset\s+--hard\b/i, "hard reset discards uncommitted work"},
    {~r/\bgit\s+checkout\s+--\s/i, "checkout -- discards local changes"},
    {~r/\b(?:shutdown|reboot|halt|poweroff|init\s+0|init\s+6)\b/i, "system power-state change"},
    {~r/\bkill(?:all)?\b[^\n]*\s-9/i, "force kill"},
    {~r/>\s*\/(?:etc|usr|bin|boot|sys|lib)\b/i, "overwrite of a system path"},
    {~r/\bnpm\s+publish\b|\btwine\s+upload\b|\bpip\s+.*\bupload\b/i, "package publish"}
  ]

  @heuristic_caution [
    {~r/\b(?:curl|wget)\b/i, "network fetch"},
    {~r/\bgit\s+(?:commit|push|merge|rebase)\b/i, "git history mutation"},
    {~r/\bdocker\b/i, "container operation"},
    {~r/\b(?:apt|apt-get|yum|dnf|brew|pacman)\b|\b(?:npm|pip|pip3|cargo|gem|go)\s+install\b/i,
     "package install"},
    {~r/\bmv\b|\bcp\b[^\n]*\s-\w*r/i, "bulk move/copy"}
  ]

  @doc "True when the model-based classifier is enabled via `:auto_mode` config."
  @spec enabled?() :: boolean()
  def enabled? do
    model_config() |> Keyword.get(:enabled, false) == true
  end

  @doc """
  Classify a tool call, combining the rule-based fast-path with a model (or
  heuristic) assessment for ambiguous cases. Always returns a `Verdict`.

  Never raises: on any internal error it degrades to the pure rule verdict.
  """
  @spec classify(map(), map()) :: Verdict.t()
  def classify(tool_call, ctx \\ %{}) do
    name = tool_name(tool_call)
    args = tool_args(tool_call)
    rule = Classifier.classify(name, args, ctx)

    cond do
      # Stage 1a — obvious danger: rules already caught it, skip the model.
      Verdict.dangerous?(rule) ->
        rule

      # Stage 1b — obvious benign: no command/mutation surface, skip the model.
      obviously_safe?(name, args, rule) ->
        rule

      # Stage 2/3 — ambiguous: ask the model (or heuristic) and take higher risk.
      true ->
        higher(rule, assess(name, args, ctx))
    end
  rescue
    e ->
      Logger.debug("[model_classifier] classify failed, deferring to rules: #{inspect(e)}")
      Classifier.classify(tool_name(tool_call), tool_args(tool_call), ctx)
  catch
    kind, reason ->
      Logger.debug("[model_classifier] classify caught #{kind}: #{inspect(reason)} — using rules")
      Classifier.classify(tool_name(tool_call), tool_args(tool_call), ctx)
  end

  # ── stage 1 gating ──────────────────────────────────────────────────

  # Obviously safe: the rules found nothing (severity 0) AND the tool is not a
  # command/mutation surface worth a model second-opinion. `:caution` verdicts
  # (severity 1) are NOT obviously safe — the model may escalate them.
  defp obviously_safe?(name, args, rule) do
    Verdict.severity(rule) == 0 and not review_worthy?(name, args)
  end

  defp review_worthy?(name, args) do
    name in @review_tools or (is_map(args) and Map.has_key?(args, "command"))
  end

  # ── stage 2/3 assessment ────────────────────────────────────────────

  defp assess(name, args, ctx) do
    cond do
      # Deterministic injection point (tests / custom integrations).
      is_function(Map.get(ctx, :assessor), 2) ->
        case ctx.assessor.(name, args) do
          %Verdict{} = v -> v
          _ -> heuristic(name, args)
        end

      enabled?() and within_budget?() ->
        case ask_model(name, args) do
          {:ok, %Verdict{} = v} -> v
          _ -> heuristic(name, args)
        end

      true ->
        heuristic(name, args)
    end
  end

  # ── model call ──────────────────────────────────────────────────────

  defp ask_model(name, args) do
    cfg = model_config()

    opts =
      []
      |> maybe_put(:provider, Keyword.get(cfg, :provider))
      |> maybe_put(:model, Keyword.get(cfg, :model))
      |> Keyword.put(:max_tokens, Keyword.get(cfg, :max_tokens, 128))
      |> Keyword.put(:temperature, 0.0)

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: user_prompt(name, args)}
    ]

    case Providers.chat(messages, opts) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        parse_model_response(content, name)

      _ ->
        :error
    end
  rescue
    e ->
      Logger.debug("[model_classifier] model call failed: #{inspect(e)}")
      :error
  catch
    kind, reason ->
      Logger.debug("[model_classifier] model call caught #{kind}: #{inspect(reason)}")
      :error
  end

  defp within_budget? do
    case OptimalSystemAgent.Agent.Budget.check_budget() do
      {:ok, _} -> true
      {:over_limit, _} -> false
      _ -> true
    end
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  @doc """
  Parse a model classification reply into `{:ok, Verdict.t}` or `:error`.

  Accepts a single-line JSON object `{"risk": "...", "reason": "..."}` (also
  tolerates `tier`/`risk_tier` keys and surrounding prose), and falls back to a
  keyword scan of free text. Public for testing.
  """
  @spec parse_model_response(String.t(), String.t() | nil) :: {:ok, Verdict.t()} | :error
  def parse_model_response(content, tool \\ nil)

  def parse_model_response(content, tool) when is_binary(content) do
    case json_verdict(content, tool) do
      {:ok, _} = ok -> ok
      :error -> regex_verdict(content, tool)
    end
  end

  def parse_model_response(_content, _tool), do: :error

  defp json_verdict(content, tool) do
    with {:ok, map} <- decode_object(content),
         raw when is_binary(raw) <- map["risk"] || map["tier"] || map["risk_tier"],
         risk when not is_nil(risk) <- normalize_risk(raw) do
      reason = clean_reason(map["reason"] || map["explanation"]) || "model flagged as #{risk}"
      {:ok, build(risk, reason, "model:#{risk}", tool)}
    else
      _ -> :error
    end
  end

  defp regex_verdict(content, tool) do
    case regex_risk(content) do
      nil -> :error
      risk -> {:ok, build(risk, "model flagged as #{risk}", "model:#{risk}", tool)}
    end
  end

  defp decode_object(content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        case Regex.run(~r/\{.*\}/s, content) do
          [json] ->
            case Jason.decode(json) do
              {:ok, map} when is_map(map) -> {:ok, map}
              _ -> :error
            end

          _ ->
            :error
        end
    end
  end

  # ── heuristic fallback ──────────────────────────────────────────────

  defp heuristic(name, args) do
    text = Classifier.primary_arg(args) || ""

    cond do
      label = find_match(@heuristic_dangerous, text) ->
        build(:dangerous, "heuristic: #{label}", "heuristic:dangerous", name)

      label = find_match(@heuristic_caution, text) ->
        build(:caution, "heuristic: #{label}", "heuristic:caution", name)

      true ->
        build(:safe, "no heuristic risk pattern matched", "heuristic:safe", name)
    end
  end

  defp find_match(table, text) do
    Enum.find_value(table, fn {re, label} -> if Regex.match?(re, text), do: label end)
  end

  # ── verdict helpers ─────────────────────────────────────────────────

  defp build(risk, reason, matched_rule, tool) do
    %Verdict{
      risk: risk,
      category: :model_flagged,
      matched_rule: matched_rule,
      reason: reason,
      tool: tool
    }
  end

  # Pick the higher-severity of two verdicts (ties keep the first / rule verdict).
  defp higher(a, b) do
    if Verdict.severity(b) > Verdict.severity(a), do: b, else: a
  end

  defp normalize_risk(raw) when is_binary(raw) do
    case raw |> String.trim() |> String.downcase() do
      "dangerous" -> :dangerous
      "danger" -> :dangerous
      "high" -> :dangerous
      "critical" -> :dangerous
      "block" -> :dangerous
      "deny" -> :dangerous
      "caution" -> :caution
      "warn" -> :caution
      "warning" -> :caution
      "medium" -> :caution
      "moderate" -> :caution
      "safe" -> :safe
      "allow" -> :safe
      "low" -> :safe
      "none" -> :safe
      "ok" -> :safe
      _ -> nil
    end
  end

  defp normalize_risk(_), do: nil

  defp regex_risk(content) do
    c = String.downcase(content)

    cond do
      String.contains?(c, "dangerous") or String.contains?(c, "danger") -> :dangerous
      String.contains?(c, "caution") or String.contains?(c, "warn") -> :caution
      String.contains?(c, "safe") or String.contains?(c, "allow") -> :safe
      true -> nil
    end
  end

  defp clean_reason(nil), do: nil

  defp clean_reason(reason) when is_binary(reason) do
    case reason |> String.trim() |> String.slice(0, 200) do
      "" -> nil
      s -> s
    end
  end

  defp clean_reason(_), do: nil

  # ── prompts ─────────────────────────────────────────────────────────

  defp system_prompt do
    """
    You are a security classifier for an autonomous coding agent running \
    unattended. Given a single proposed tool call, rate its risk to the user's \
    system, code, or data as exactly one of: safe, caution, dangerous.

    Treat as dangerous anything destructive or irreversible (mass deletion, \
    disk/filesystem writes, force git operations), secret exfiltration, \
    privilege escalation, or production/infra mutation. Treat routine reads, \
    local edits, and scoped builds/tests as safe. Use caution for reversible \
    but noteworthy actions.

    Reply with ONE line of JSON and nothing else:
    {"risk":"safe|caution|dangerous","reason":"<short one-line justification>"}
    """
  end

  defp user_prompt(name, args) do
    arg_str =
      case Jason.encode(args) do
        {:ok, json} -> String.slice(json, 0, 1000)
        _ -> args |> inspect() |> String.slice(0, 1000)
      end

    "Tool: #{name}\nArguments: #{arg_str}\n\nClassify the risk of running this tool call."
  end

  # ── misc ────────────────────────────────────────────────────────────

  defp model_config do
    Application.get_env(:optimal_system_agent, :auto_mode, [])
    |> Keyword.get(:model_classifier, [])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp tool_name(tc) when is_map(tc), do: Map.get(tc, :name) || Map.get(tc, "name")
  defp tool_name(_), do: nil

  defp tool_args(tc) when is_map(tc), do: Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{}
  defp tool_args(_), do: %{}
end
