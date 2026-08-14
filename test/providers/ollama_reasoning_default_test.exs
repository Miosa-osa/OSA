defmodule OptimalSystemAgent.Providers.OllamaReasoningDefaultTest do
  @moduledoc """
  Reasoning must be ON by default for CLOUD-served Ollama models, and the
  stall guard must stay ON for LOCALLY-served ones.

  The defect this pins: `maybe_add_think/3` selected the `think: false` default
  with a CAPABILITY test (`thinking_model?/1`), so it disabled reasoning on
  exactly the reasoning-capable models — including `:cloud` tags, where the
  stall risk belongs to the provider and the user is paying for the capability.
  Measured: cline's Terminal-Bench 2.0 run on glm-5.2 scored 68.5% with
  reasoning vs 57.3% without.

  `async: false` — these mutate `:ollama_think` application env.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Observability
  alias OptimalSystemAgent.Providers.Ollama

  # A cloud tag that is also reasoning-capable in the OllamaCloud catalog.
  @cloud "glm-5.2:cloud"
  # The size-qualified hosted tag shape, which a plain `contains?(":cloud")`
  # would miss.
  @cloud_sized "gpt-oss:120b-cloud"
  # Locally served reasoning models — the real stall risk.
  @local "kimi-k2"
  @local_thinking "qwen3-thinking:14b"
  # No reasoning mode at all.
  @flat "llama3.1:70b"

  setup do
    prev = Application.get_env(:optimal_system_agent, :ollama_think)
    Application.delete_env(:optimal_system_agent, :ollama_think)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:optimal_system_agent, :ollama_think)
        v -> Application.put_env(:optimal_system_agent, :ollama_think, v)
      end
    end)

    :ok
  end

  describe "cloud-served reasoning models get reasoning BY DEFAULT" do
    test "a :cloud tag sends think: true with no configuration at all" do
      assert {true, :cloud_default} = Ollama.reasoning_decision(@cloud, [])
      assert Ollama.apply_think(%{}, @cloud, [])["think"] == true
    end

    test "the size-qualified '-cloud' tag shape counts as cloud too" do
      assert Ollama.cloud_model?(@cloud_sized)
      assert {true, :cloud_default} = Ollama.reasoning_decision(@cloud_sized, [])
    end

    test "regression: a cloud reasoning model is NEVER silently sent think: false" do
      refute Ollama.apply_think(%{}, @cloud, [])["think"] == false
    end
  end

  describe "locally served reasoning models KEEP the stall guard" do
    test "a local reasoning model still defaults to think: false" do
      assert {false, :local_stall_guard} = Ollama.reasoning_decision(@local, [])
      assert Ollama.apply_think(%{}, @local, [])["think"] == false
    end

    test "the guard covers heuristic-matched local reasoning tags" do
      assert {false, :local_stall_guard} = Ollama.reasoning_decision(@local_thinking, [])
    end
  end

  describe "models with no reasoning mode send no field" do
    test "non-reasoning model leaves the body untouched" do
      assert {nil, :unsupported} = Ollama.reasoning_decision(@flat, [])
      body = %{model: @flat, messages: []}
      assert Ollama.apply_think(body, @flat, []) == body
      refute Map.has_key?(Ollama.apply_think(body, @flat, []), "think")
    end
  end

  describe "explicit configuration overrides BOTH directions and BOTH modes" do
    test "opts[:think] = false disables a cloud model" do
      assert {false, :opt} = Ollama.reasoning_decision(@cloud, think: false)
      assert Ollama.apply_think(%{}, @cloud, think: false)["think"] == false
    end

    test "opts[:think] = true enables a local model (stall risk accepted)" do
      assert {true, :opt} = Ollama.reasoning_decision(@local, think: true)
    end

    test "OLLAMA_THINK=false disables a cloud model" do
      Application.put_env(:optimal_system_agent, :ollama_think, false)
      assert {false, :config} = Ollama.reasoning_decision(@cloud, [])
    end

    test "OLLAMA_THINK=true enables a local model" do
      Application.put_env(:optimal_system_agent, :ollama_think, true)
      assert {true, :config} = Ollama.reasoning_decision(@local, [])
    end

    test "a per-call opt beats the global config" do
      Application.put_env(:optimal_system_agent, :ollama_think, false)
      assert {true, :opt} = Ollama.reasoning_decision(@cloud, think: true)
    end

    test "config forces a value even on a model with no reasoning mode" do
      # Explicit means explicit: the operator asked for the field.
      Application.put_env(:optimal_system_agent, :ollama_think, true)
      assert {true, :config} = Ollama.reasoning_decision(@flat, [])
    end
  end

  describe "prefix stability" do
    test "the decision is constant across turns for a fixed model + config" do
      decisions = for _ <- 1..25, do: Ollama.reasoning_decision(@cloud, [])
      assert Enum.uniq(decisions) == [{true, :cloud_default}]
    end

    test "it is a request-body field, never prompt content" do
      body = Ollama.apply_think(%{model: @cloud, messages: [%{role: "user"}]}, @cloud, [])
      assert body["think"] == true
      # messages are untouched, so no cached prefix can be perturbed
      assert body.messages == [%{role: "user"}]
    end
  end

  describe "the setting is recorded in turn telemetry" do
    test "turn_start/turn_end carry the reasoning condition alongside effort" do
      state = %{session_id: "s", turn_id: "t", provider: :ollama, model: @cloud}
      assert Observability.current_reasoning(state) == "on:cloud_default"
      assert Observability.turn_start(state) == :ok
      assert Observability.turn_end(state, "done") == :ok
    end

    test "a locally guarded model is recorded as off, with the reason" do
      state = %{session_id: "s", turn_id: "t", provider: :ollama, model: @local}
      assert Observability.current_reasoning(state) == "off:local_stall_guard"
    end

    test "an operator-chosen value is distinguishable from an inherited default" do
      Application.put_env(:optimal_system_agent, :ollama_think, true)
      state = %{session_id: "s", turn_id: "t", provider: :ollama, model: @local}
      assert Observability.current_reasoning(state) == "on:config"
    end

    test "non-ollama providers and unknown state record nil, not a fabricated value" do
      assert Observability.current_reasoning(%{provider: :anthropic, model: "claude-opus-4-6"}) ==
               nil

      assert Observability.current_reasoning(%{}) == nil
      assert Observability.current_reasoning(%{provider: :ollama, model: @flat}) == nil
      assert Observability.current_reasoning(%{provider: "no_such_provider_atom_xyz"}) == nil
    end
  end
end
