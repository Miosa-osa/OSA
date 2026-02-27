defmodule OptimalSystemAgent.Providers.Perplexity do
  @moduledoc """
  Perplexity AI provider — search-augmented language models.

  OpenAI-compatible endpoint. Sonar models include real-time web search
  grounding, making them ideal for tasks requiring up-to-date information.

  Config keys:
    :perplexity_api_key — required (PERPLEXITY_API_KEY)
    :perplexity_model   — (default: sonar-pro)
    :perplexity_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.perplexity.ai"

  @impl true
  def name, do: :perplexity

  @impl true
  def default_model, do: "sonar-pro"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :perplexity_api_key)
    model = Application.get_env(:optimal_system_agent, :perplexity_model, default_model())
    url = Application.get_env(:optimal_system_agent, :perplexity_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, opts) do
      {:error, "API key not configured"} ->
        {:error, "PERPLEXITY_API_KEY not configured"}

      other ->
        other
    end
  end
end
