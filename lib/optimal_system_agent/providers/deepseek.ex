defmodule OptimalSystemAgent.Providers.DeepSeek do
  @moduledoc """
  DeepSeek provider — strong reasoning and coding models.

  OpenAI-compatible endpoint. DeepSeek-V3 and DeepSeek-R1 are highly
  competitive with frontier models at a fraction of the cost.

  Config keys:
    :deepseek_api_key — required (DEEPSEEK_API_KEY)
    :deepseek_model   — (default: deepseek-chat)
    :deepseek_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.deepseek.com/v1"

  @impl true
  def name, do: :deepseek

  @impl true
  def default_model, do: "deepseek-chat"

  @impl true
  def available_models do
    ["deepseek-chat", "deepseek-reasoner"]
  end

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :deepseek_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :deepseek_model, default_model())

    url = Application.get_env(:optimal_system_agent, :deepseek_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, Keyword.delete(opts, :model)) do
      {:error, "API key not configured"} ->
        {:error, "DEEPSEEK_API_KEY not configured"}

      other ->
        other
    end
  end
end
