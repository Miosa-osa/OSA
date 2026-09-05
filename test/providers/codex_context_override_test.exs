defmodule OptimalSystemAgent.Providers.CodexContextOverrideTest do
  use ExUnit.Case, async: true
  alias OptimalSystemAgent.Providers.OpenAICodex

  test "configured window reaches the shared resolver and resumed context budget" do
    session = "codex-window-#{System.unique_integer([:positive])}"
    Process.put(:osa_session_id, session)

    # Under the 872k Codex transport maximum, so what this test observes is the
    # override travelling, not the ceiling clamping it.
    OptimalSystemAgent.Settings.set_session_for(session, "codex_context_windows", %{
      "gpt-6-astra" => 800_000
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

    assert OptimalSystemAgent.Agent.Loop.ContextWindow.resolve(state) == {:ok, 800_000}
    assert OptimalSystemAgent.Agent.Context.token_budget(state).max_tokens == 800_000

    assert OptimalSystemAgent.Providers.Registry.effective_context_window("gpt-6-astra", :openai) ==
             1_050_000
  end

  test "a million-token budget is capped at what the Codex transport accepts" do
    overrides =
      Map.new(
        ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
        &{&1, 1_000_000}
      )

    # The 1.05M on these model cards is the PUBLIC API's window. Codex
    # advertises 872k for the same ids, and a budget built to the public number
    # over-fills this endpoint: compaction never fires, and the turn dies at
    # the wire with an empty HTTP 400 instead.
    for model <- Map.keys(overrides) do
      assert OpenAICodex.context_window(model, overrides) == 872_000
    end

    assert OpenAICodex.context_window("gpt-5.3-codex-spark", overrides) == 128_000
    assert OpenAICodex.context_window("gpt-5.5", overrides) == 272_000
  end

  test "invalid settings fall back and oversized settings cannot exceed catalog ceilings" do
    for invalid <- [nil, [], "1000000", %{"gpt-6-astra" => -1}, %{"gpt-6-astra" => "1000000"}] do
      assert OpenAICodex.context_window("gpt-6-astra", invalid) == 872_000
    end

    assert OpenAICodex.context_window("gpt-6-astra", %{"gpt-6-astra" => 9_000_000}) == 872_000

    # The gap that used to slip through: between the transport maximum and the
    # published model card, `min/2` against the card alone let the override
    # stand and over-budgeted the endpoint by up to 178k tokens.
    assert OpenAICodex.context_window("gpt-6-astra", %{"gpt-6-astra" => 900_000}) == 872_000

    # Clamping is one-directional. An override BELOW the transport maximum is a
    # client budget and still applies.
    assert OpenAICodex.context_window("gpt-6-astra", %{"gpt-6-astra" => 500_000}) == 500_000

    assert OpenAICodex.context_window("gpt-5.3-codex-spark", %{"gpt-5.3-codex-spark" => 1_000_000}) ==
             128_000

    assert OpenAICodex.context_window("unknown", %{"unknown" => 1_000_000}) == nil
  end
end
