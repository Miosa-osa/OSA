defmodule OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  The `delegate` tool name is referenced in `MixtureOfAgents.Prompt` so that
  renaming `delegate` propagates here automatically via the lazy `safe_ref/3`
  pattern.
  """

  @tool_name "mixture_of_agents"
  def tool_name, do: @tool_name

  # Default providers checked in priority order.
  @candidate_providers [
    :anthropic,
    :openai,
    :groq,
    :together,
    :openrouter,
    :google,
    :cohere,
    :ollama
  ]
  def candidate_providers, do: @candidate_providers

  # Per-provider timeout when fanning out in parallel.
  @provider_timeout_ms 30_000
  def provider_timeout_ms, do: @provider_timeout_ms

  # Max tokens for the synthesis step.
  @synthesis_max_tokens 4_096
  def synthesis_max_tokens, do: @synthesis_max_tokens
end
