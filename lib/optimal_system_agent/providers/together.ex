defmodule OptimalSystemAgent.Providers.Together do
  @moduledoc """
  Together AI provider — open-source model hosting.

  OpenAI-compatible endpoint with access to Llama, Mixtral, and other
  open-weight models at competitive pricing.

  Config keys:
    :together_api_key — required (TOGETHER_API_KEY)
    :together_model   — (default: meta-llama/Llama-3.3-70B-Instruct-Turbo)
    :together_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.together.xyz/v1"

  @impl true
  def name, do: :together

  @impl true
  def default_model, do: "meta-llama/Llama-3.3-70B-Instruct-Turbo"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :together_api_key)
    model = Keyword.get(opts, :model) || Application.get_env(:optimal_system_agent, :together_model, default_model())
    url = Application.get_env(:optimal_system_agent, :together_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, Keyword.delete(opts, :model)) do
      {:error, "API key not configured"} ->
        {:error, "TOGETHER_API_KEY not configured"}

      other ->
        other
    end
  end
end
