defmodule OptimalSystemAgent.Providers.Qwen do
  @moduledoc """
  Alibaba Qwen (DashScope) provider.

  OpenAI-compatible endpoint. Qwen-Max and Qwen-Plus are strong
  multilingual models with excellent Chinese language support.

  Config keys:
    :qwen_api_key — required (DASHSCOPE_API_KEY)
    :qwen_model   — (default: qwen-max)
    :qwen_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://dashscope.aliyuncs.com/compatible-mode/v1"

  @impl true
  def name, do: :qwen

  @impl true
  def default_model, do: "qwen-max"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :qwen_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :qwen_model, default_model())

    url = Application.get_env(:optimal_system_agent, :qwen_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, Keyword.delete(opts, :model)) do
      {:error, "API key not configured"} ->
        {:error, "DASHSCOPE_API_KEY (qwen_api_key) not configured"}

      other ->
        other
    end
  end
end
