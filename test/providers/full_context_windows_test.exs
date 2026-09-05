defmodule OptimalSystemAgent.Providers.FullContextWindowsTest do
  use ExUnit.Case, async: false
  alias OptimalSystemAgent.Providers
  alias OptimalSystemAgent.Agent.Loop.{ContextWindow, CompactionThresholds}

  test "native hosted catalogs retain each model's full window" do
    for {provider, catalog} <- [
          {:openai, Providers.OpenAIModels},
          {:anthropic, Providers.AnthropicModels},
          {:google, Providers.GoogleModels},
          {:xai, Providers.XAIModels},
          {:deepseek, Providers.DeepSeekModels},
          {:mistral, Providers.MistralModels},
          # z.ai / GLM was ABSENT from this list, so its catalog silently drifted
          # from the Registry: GLM models were never merged in and resolved to
          # stale hardcoded rows / prefix guesses (the default glm-5.3-flash, a
          # real 1M window, read as 200K). Every hosted catalog belongs here.
          {:zai, Providers.ZaiModels}
        ],
        {model, expected} <- catalog.context_windows() do
      assert Providers.Registry.effective_context_window(model, provider) == expected,
             "#{provider}/#{model} was capped or given another model's window"

      assert ContextWindow.resolve(%{model: model, provider: provider}) == {:ok, expected}
      assert CompactionThresholds.operative_window(expected) == expected
    end
  end

  test "resumed session breakdown re-resolves the model instead of keeping an old cap" do
    state = %{
      model: "gpt-6-astra",
      provider: :openai_codex,
      effective_context_window: 272_000,
      session_id: "window-upgrade",
      messages: [],
      channel: :cli,
      plan_mode: false,
      working_dir: "/tmp"
    }

    assert OptimalSystemAgent.Agent.Context.token_budget(state).max_tokens == 872_000
  end
end
