defmodule OptimalSystemAgent.Providers.ReasoningCapability do
  @moduledoc """
  Can reasoning be switched OFF on this provider/model?

  Some models reason no matter what the request says: Claude Opus 5.5 400s on
  `thinking: {type: "disabled"}`, GLM-5.3 Flash's effort ladder has no
  `"none"` rung, and the GLM tags on Ollama Cloud reason even with
  `think: false` (it only moves the chain-of-thought into the answer). Offering
  "thinking off" for those models is a control that does nothing — or worse,
  claims a state the model is not in.

  The answer comes from each provider's source-of-truth catalog, never from a
  model-name pattern:

    * `:anthropic` / `:bedrock` — `AnthropicModels.thinking_can_disable?/1`
    * `:zhipu` (Z.ai) — `ZaiModels.thinking_can_disable?/1` (the effort vocabulary)
    * `:ollama` — `OllamaCloud.thinking_always_on?/1`

  Anything a catalog does not describe answers `true`: hiding a working
  control on a guess is its own defect.
  """

  alias OptimalSystemAgent.Providers.{AnthropicModels, OllamaCloud, ZaiModels}

  @spec can_disable?(atom() | String.t() | nil, String.t() | nil) :: boolean()
  def can_disable?(provider, model) when is_binary(model) do
    case to_string(provider || "") do
      p when p in ["anthropic", "bedrock"] -> AnthropicModels.thinking_can_disable?(model)
      p when p in ["zhipu", "zai"] -> ZaiModels.thinking_can_disable?(model)
      "ollama" -> not OllamaCloud.thinking_always_on?(model)
      _ -> true
    end
  rescue
    _ -> true
  end

  def can_disable?(_provider, _model), do: true

  @doc "The sentence shown when someone asks to turn thinking off anyway."
  @spec cannot_disable_message(String.t()) :: String.t()
  def cannot_disable_message(model) do
    "#{model} always reasons — thinking can't be turned off for this model. " <>
      "Pick a lower effort with /reasoning, or /model to switch models."
  end
end
