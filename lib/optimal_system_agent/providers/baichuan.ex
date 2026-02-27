defmodule OptimalSystemAgent.Providers.Baichuan do
  @moduledoc """
  Baichuan AI provider.

  OpenAI-compatible endpoint. Baichuan4 is a strong Chinese language
  model with good performance on Chinese NLP benchmarks.

  Config keys:
    :baichuan_api_key — required (BAICHUAN_API_KEY)
    :baichuan_model   — (default: Baichuan4)
    :baichuan_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.baichuan-ai.com/v1"

  @impl true
  def name, do: :baichuan

  @impl true
  def default_model, do: "Baichuan4"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :baichuan_api_key)
    model = Keyword.get(opts, :model) || Application.get_env(:optimal_system_agent, :baichuan_model, default_model())
    url = Application.get_env(:optimal_system_agent, :baichuan_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, Keyword.delete(opts, :model)) do
      {:error, "API key not configured"} ->
        {:error, "BAICHUAN_API_KEY not configured"}

      other ->
        other
    end
  end
end
