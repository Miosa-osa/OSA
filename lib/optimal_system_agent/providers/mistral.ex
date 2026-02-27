defmodule OptimalSystemAgent.Providers.Mistral do
  @moduledoc """
  Mistral AI provider — European frontier models.

  OpenAI-compatible endpoint. Mistral Large and Codestral are strong
  options for coding and multilingual tasks with European data residency.

  Config keys:
    :mistral_api_key — required (MISTRAL_API_KEY)
    :mistral_model   — (default: mistral-large-latest)
    :mistral_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.mistral.ai/v1"

  @impl true
  def name, do: :mistral

  @impl true
  def default_model, do: "mistral-large-latest"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :mistral_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :mistral_model, default_model())

    url = Application.get_env(:optimal_system_agent, :mistral_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, Keyword.delete(opts, :model)) do
      {:error, "API key not configured"} ->
        {:error, "MISTRAL_API_KEY not configured"}

      other ->
        other
    end
  end
end
