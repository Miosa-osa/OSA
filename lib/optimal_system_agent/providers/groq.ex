defmodule OptimalSystemAgent.Providers.Groq do
  @moduledoc """
  Groq provider — ultra-fast inference via LPU hardware.

  OpenAI-compatible endpoint. Excellent for latency-sensitive tasks.

  Config keys:
    :groq_api_key — required (GROQ_API_KEY)
    :groq_model   — (default: llama-3.3-70b-versatile)
    :groq_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompat

  @default_url "https://api.groq.com/openai/v1"

  @impl true
  def name, do: :groq

  @impl true
  def default_model, do: "llama-3.3-70b-versatile"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :groq_api_key)
    model = Application.get_env(:optimal_system_agent, :groq_model, default_model())
    url = Application.get_env(:optimal_system_agent, :groq_url, @default_url)

    case OpenAICompat.chat(url, api_key, model, messages, opts) do
      {:error, "API key not configured"} ->
        {:error, "GROQ_API_KEY not configured"}

      other ->
        other
    end
  end
end
