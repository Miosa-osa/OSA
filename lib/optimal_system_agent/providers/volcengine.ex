defmodule OptimalSystemAgent.Providers.Volcengine do
  @moduledoc """
  VolcEngine (ByteDance Doubao) provider.

  OpenAI-compatible endpoint. Doubao-Pro is ByteDance's flagship model
  with strong Chinese language capabilities and a 128k context window.

  Config keys:
    :volcengine_api_key — required (VOLCENGINE_API_KEY / ARK_API_KEY)
    :volcengine_model   — (default: doubao-pro-128k)
    :volcengine_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://ark.cn-beijing.volces.com/api/v3"

  @impl true
  def name, do: :volcengine

  @impl true
  def default_model, do: "doubao-pro-128k"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :volcengine_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :volcengine_model, default_model())

    url = Application.get_env(:optimal_system_agent, :volcengine_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, Keyword.delete(opts, :model)) do
      {:error, "API key not configured"} ->
        {:error, "VOLCENGINE_API_KEY not configured"}

      other ->
        other
    end
  end
end
