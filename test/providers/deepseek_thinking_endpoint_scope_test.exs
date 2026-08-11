defmodule OptimalSystemAgent.Providers.DeepSeekThinkingEndpointScopeTest do
  @moduledoc """
  A provider-proprietary body decoration is scoped by the ENDPOINT, not the
  model name.

  `maybe_add_provider_thinking/3` gated on
  `DeepSeekModels.thinking_params(model, effort)` — a pure model-NAME test with
  no notion of where the request is going. `OpenAICompat` is the shared
  transport for OpenRouter, Groq, LM Studio and every user-defined `base_url`,
  and all of them host DeepSeek weights under DeepSeek's own names. Serving
  `deepseek/deepseek-v3.2` via OpenRouter therefore merged DeepSeek's
  proprietary top-level `thinking` object into a body OpenRouter answers with a
  400 for an unknown field.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.OpenAICompat

  @deepseek_url "https://api.deepseek.com/v1"
  @openrouter_url "https://openrouter.ai/api/v1"
  @local_url "http://localhost:1234/v1"

  # Whatever DeepSeek's own catalogue calls its thinking models — resolved from
  # the same source the production gate uses, so this test cannot drift from it.
  @model "deepseek-v4-flash"

  setup do
    prev = Application.fetch_env(:optimal_system_agent, :deepseek_url)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :deepseek_url, v)
        :error -> Application.delete_env(:optimal_system_agent, :deepseek_url)
      end
    end)

    :ok
  end

  defp thinking_keys(body),
    do: body |> Map.keys() |> Enum.filter(&(to_string(&1) == "thinking"))

  test "precondition: this model really does carry DeepSeek thinking params" do
    body = OpenAICompat.build_stream_body(@model, [], [reasoning_effort: "high"], @deepseek_url)

    assert thinking_keys(body) != [],
           "the fixture model must be one the DeepSeek catalogue recognises, or this " <>
             "whole test proves nothing"
  end

  test "the thinking object is NOT sent to a third-party gateway serving the same model" do
    for url <- [@openrouter_url, @local_url] do
      body = OpenAICompat.build_stream_body(@model, [], [reasoning_effort: "high"], url)

      assert thinking_keys(body) == [],
             "#{url} rejects an unknown top-level `thinking` field with a 400: " <>
               inspect(body)

      refute Map.has_key?(body, "thinking"), inspect(body)
    end
  end

  test "a proxied :deepseek base_url still counts as DeepSeek" do
    proxy = "https://deepseek.internal.example/v1"
    Application.put_env(:optimal_system_agent, :deepseek_url, proxy)

    body = OpenAICompat.build_stream_body(@model, [], [reasoning_effort: "high"], proxy)

    assert thinking_keys(body) != [],
           "scoping by endpoint must not break a user who proxies DeepSeek through " <>
             "their own host"
  end

  test "an OpenAI model is unaffected either way" do
    for url <- [@deepseek_url, @openrouter_url] do
      body = OpenAICompat.build_stream_body("gpt-4o", [], [reasoning_effort: "high"], url)
      assert thinking_keys(body) == []
    end
  end
end
