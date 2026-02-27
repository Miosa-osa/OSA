defmodule OptimalSystemAgent.Providers.OpenAI do
  @moduledoc """
  OpenAI provider (GPT-4o, GPT-4o-mini, o1, etc.).

  Uses the OpenAI Chat Completions API via the shared OpenAICompat module.

  Config keys:
    :openai_api_key — required
    :openai_model   — (default: gpt-4o)
    :openai_url     — override base URL (default: https://api.openai.com/v1)
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.openai.com/v1"

  @impl true
  def name, do: :openai

  @impl true
  def default_model, do: "gpt-4o"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :openai_api_key)
    model = Application.get_env(:optimal_system_agent, :openai_model, default_model())
    url = Application.get_env(:optimal_system_agent, :openai_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, opts) do
      {:error, "API key not configured"} ->
        {:error, "OPENAI_API_KEY not configured"}

      other ->
        other
    end
  end
end
