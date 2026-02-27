defmodule OptimalSystemAgent.Providers.OpenRouter do
  @moduledoc """
  OpenRouter provider — access 100+ models through one API.

  OpenAI-compatible endpoint. Routes to OpenAI, Anthropic, Google, Meta,
  Mistral, and many more via a unified API.

  Config keys:
    :openrouter_api_key — required (OPENROUTER_API_KEY)
    :openrouter_model   — (default: meta-llama/llama-3.3-70b-instruct)
    :openrouter_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://openrouter.ai/api/v1"

  @impl true
  def name, do: :openrouter

  @impl true
  def default_model, do: "meta-llama/llama-3.3-70b-instruct"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :openrouter_api_key)
    model = Application.get_env(:optimal_system_agent, :openrouter_model, default_model())
    url = Application.get_env(:optimal_system_agent, :openrouter_url, @default_url)

    opts =
      Keyword.put(opts, :extra_headers, [
        {"HTTP-Referer", "https://github.com/Miosa-osa/OSA"},
        {"X-Title", "OSA"}
      ])

    case OpenAICompat.chat(url, api_key, model, messages, opts) do
      {:error, "API key not configured"} ->
        {:error, "OPENROUTER_API_KEY not configured"}

      other ->
        other
    end
  end
end
