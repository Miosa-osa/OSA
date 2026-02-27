defmodule OptimalSystemAgent.Providers.Fireworks do
  @moduledoc """
  Fireworks AI provider — fast open-source model inference.

  OpenAI-compatible endpoint specializing in Llama and other open-weight
  models with compound AI system support.

  Config keys:
    :fireworks_api_key — required (FIREWORKS_API_KEY)
    :fireworks_model   — (default: accounts/fireworks/models/llama-v3p3-70b-instruct)
    :fireworks_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.fireworks.ai/inference/v1"

  @impl true
  def name, do: :fireworks

  @impl true
  def default_model, do: "accounts/fireworks/models/llama-v3p3-70b-instruct"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :fireworks_api_key)
    model = Keyword.get(opts, :model) || Application.get_env(:optimal_system_agent, :fireworks_model, default_model())
    url = Application.get_env(:optimal_system_agent, :fireworks_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, Keyword.delete(opts, :model)) do
      {:error, "API key not configured"} ->
        {:error, "FIREWORKS_API_KEY not configured"}

      other ->
        other
    end
  end
end
