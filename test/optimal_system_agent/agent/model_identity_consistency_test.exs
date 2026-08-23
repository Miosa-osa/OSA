defmodule OptimalSystemAgent.Agent.ModelIdentityConsistencyTest do
  @moduledoc """
  The system prompt must tell the model ONE identity, and it must be the model
  actually routed for the session.

  Regression: `environment_block` resolved the model on its own
  (`state.model || get_active_model(provider)`) and fell back to the provider's
  CONFIG DEFAULT when the session had not pinned `state.model`. On an OpenRouter
  session running `stealth/ox-alpha` that made the environment line announce
  `anthropic/claude-opus-5` (the openrouter default) while the runtime block and
  the TUI footer said `stealth/ox-alpha`. Two contradictory identity lines let
  the model confidently misreport what it is. Both lines now resolve through the
  one canonical `Runtime.Identity`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context

  defp state(session, provider, model) do
    %{
      session_id: session,
      messages: [%{role: "user", content: "what model are you"}],
      working_dir: File.cwd!(),
      channel: :cli,
      provider: provider,
      model: model,
      permission_tier: :full
    }
  end

  defp system_text(state) do
    %{messages: [sys | _]} = Context.build(state)

    case sys.content do
      c when is_binary(c) -> c
      parts when is_list(parts) -> Enum.map_join(parts, "\n", &(&1[:text] || &1["text"] || ""))
    end
  end

  test "a session pinned to stealth/ox-alpha never announces the openrouter default model" do
    text = system_text(state("id-#{System.unique_integer([:positive])}", :openrouter, "stealth/ox-alpha"))

    assert text =~ "stealth/ox-alpha"
    refute text =~ "claude-opus-5",
           "the environment line must not fall back to the provider config default"
  end

  test "the environment line and the runtime line report the SAME model" do
    text = system_text(state("id-#{System.unique_integer([:positive])}", :openrouter, "stealth/ox-alpha"))

    # runtime block: "- Model: <m> (provider ...)"
    runtime_model =
      Regex.run(~r/- Model:\s*(\S+)/, text) |> then(fn [_, m] -> m end)

    # environment block: "powered by the model `<m>`"
    env_model =
      Regex.run(~r/powered by the model `([^`]+)`/, text) |> then(fn [_, m] -> m end)

    assert runtime_model == env_model
    assert env_model == "stealth/ox-alpha"
  end
end
