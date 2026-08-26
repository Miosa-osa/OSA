defmodule OptimalSystemAgent.Providers.SessionModelReachesWireTest do
  @moduledoc """
  The model the session is switched to must be the model the request is
  actually made with — not a config default, not an alias. Locks the chain
  `/model` -> `state.model` -> request body, so "what model are you" can never
  again be a different model than the one on the wire.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.OpenAICompat
  alias OptimalSystemAgent.Providers.ConfiguredModel
  alias OptimalSystemAgent.Agent.Loop.ModelSwap

  test "the request body carries the exact session model, verbatim" do
    body = OpenAICompat.build_stream_body("stealth/ox-alpha", [%{role: "user", content: "hi"}], [])
    assert body.model == "stealth/ox-alpha"
  end

  test "an explicit session model wins over the provider's configured default" do
    # explicit(opts) is consulted before configured(provider) / fallback, so a
    # session pinned to ox-alpha is never silently replaced by the openrouter
    # default (anthropic/claude-opus-5).
    assert ConfiguredModel.resolve([model: "stealth/ox-alpha"], :openrouter, "anthropic/claude-opus-5") ==
             "stealth/ox-alpha"
  end

  test "swapping the model updates the running loop's state.model (the value that reaches the wire)" do
    state = %{
      session_id: "wire-#{System.unique_integer([:positive])}",
      provider: :openrouter,
      model: "anthropic/claude-opus-5",
      messages: [%{role: "user", content: "hi"}],
      effective_context_window: 200_000
    }

    {new_state, info} = ModelSwap.apply(state, :openrouter, "stealth/ox-alpha", 1_048_576)

    assert new_state.model == "stealth/ox-alpha"
    assert new_state.provider == :openrouter
    assert info.model == "stealth/ox-alpha"
  end
end
