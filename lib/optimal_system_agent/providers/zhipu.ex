defmodule OptimalSystemAgent.Providers.Zhipu do
  @moduledoc """
  Zhipu AI (ChatGLM) provider.

  OpenAI-compatible endpoint. GLM-4 series models are strong Chinese
  language models developed by Tsinghua University and Zhipu AI.

  Config keys:
    :zhipu_api_key — required (ZHIPU_API_KEY)
    :zhipu_model   — (default: glm-4-plus)
    :zhipu_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://open.bigmodel.cn/api/paas/v4"

  @impl true
  def name, do: :zhipu

  @impl true
  def default_model, do: "glm-4-plus"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :zhipu_api_key)
    model = Application.get_env(:optimal_system_agent, :zhipu_model, default_model())
    url = Application.get_env(:optimal_system_agent, :zhipu_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, opts) do
      {:error, "API key not configured"} ->
        {:error, "ZHIPU_API_KEY not configured"}

      other ->
        other
    end
  end
end
