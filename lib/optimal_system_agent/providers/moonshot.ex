defmodule OptimalSystemAgent.Providers.Moonshot do
  @moduledoc """
  Moonshot AI (Kimi) provider.

  OpenAI-compatible endpoint. Moonshot-v1-128k offers a very large
  context window with strong Chinese language capabilities.

  Config keys:
    :moonshot_api_key — required (MOONSHOT_API_KEY)
    :moonshot_model   — (default: moonshot-v1-128k)
    :moonshot_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.moonshot.cn/v1"

  @impl true
  def name, do: :moonshot

  @impl true
  def default_model, do: "moonshot-v1-128k"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :moonshot_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :moonshot_model, default_model())

    url = Application.get_env(:optimal_system_agent, :moonshot_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, Keyword.delete(opts, :model)) do
      {:error, "API key not configured"} ->
        {:error, "MOONSHOT_API_KEY not configured"}

      other ->
        other
    end
  end
end
