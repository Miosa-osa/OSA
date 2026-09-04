defmodule OptimalSystemAgent.Providers.CodexContextOverrideTest do
  use ExUnit.Case, async: true
  alias OptimalSystemAgent.Providers.OpenAICodex

  test "configured window reaches the shared resolver and resumed context budget" do
    session = "codex-window-#{System.unique_integer([:positive])}"
    Process.put(:osa_session_id, session)

    OptimalSystemAgent.Settings.set_session_for(session, "codex_context_windows", %{
      "gpt-6-astra" => 1_000_000
    })

    on_exit(fn -> OptimalSystemAgent.Settings.clear_session(session) end)

    state = %{
      session_id: session,
      model: "gpt-6-astra",
      provider: :openai_codex,
      effective_context_window: 272_000,
      messages: [],
      channel: :cli,
      plan_mode: false,
      working_dir: "/tmp"
    }

    assert OptimalSystemAgent.Agent.Loop.ContextWindow.resolve(state) == {:ok, 1_000_000}
    assert OptimalSystemAgent.Agent.Context.token_budget(state).max_tokens == 1_000_000

    assert OptimalSystemAgent.Providers.Registry.effective_context_window("gpt-6-astra", :openai) ==
             1_050_000
  end

  test "explicit million-token budgets apply only to the named models" do
    overrides =
      Map.new(
        ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
        &{&1, 1_000_000}
      )

    for model <- Map.keys(overrides) do
      assert OpenAICodex.context_window(model, overrides) == 1_000_000
    end

    assert OpenAICodex.context_window("gpt-5.3-codex-spark", overrides) == 128_000
    assert OpenAICodex.context_window("gpt-5.5", overrides) == 272_000
  end

  test "invalid settings fall back and oversized settings cannot exceed catalog ceilings" do
    for invalid <- [nil, [], "1000000", %{"gpt-6-astra" => -1}, %{"gpt-6-astra" => "1000000"}] do
      assert OpenAICodex.context_window("gpt-6-astra", invalid) == 872_000
    end

    assert OpenAICodex.context_window("gpt-6-astra", %{"gpt-6-astra" => 9_000_000}) == 1_050_000

    assert OpenAICodex.context_window("gpt-5.3-codex-spark", %{"gpt-5.3-codex-spark" => 1_000_000}) ==
             128_000

    assert OpenAICodex.context_window("unknown", %{"unknown" => 1_000_000}) == nil
  end
end
