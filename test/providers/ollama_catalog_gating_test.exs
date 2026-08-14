defmodule OptimalSystemAgent.Providers.OllamaCatalogGatingTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Ollama

  describe "model_supports_tools?/1" do
    test "keeps the name heuristic when the catalog has no entry" do
      assert Ollama.model_supports_tools?("qwen3:8b")

      # An unrecognised NAME is no longer grounds for withholding the toolbox —
      # the prefix list is fixed, so every model released after it was written
      # failed it, and the result was an agent that could not act. Refusal now
      # needs evidence: an embedding model, or one too small to hold the
      # schemas. See `tools_decision/2` and `silent_capability_loss_test.exs`.
      assert {true, :unknown_model_default} = Ollama.tools_decision("some-unknown-model", [])
      refute Ollama.model_supports_tools?("nomic-embed-text:latest")
    end

    test "prefers the catalog tool_call flag over the name heuristic" do
      # gpt-4o has no tool-capable NAME prefix for Ollama, but the catalog marks
      # it tool_call: true — catalog authority must win.
      assert Ollama.model_supports_tools?("gpt-4o")
    end
  end

  describe "thinking_model?/1" do
    test "detects reasoning tags the old heuristic missed" do
      assert Ollama.thinking_model?("deepseek-r1:7b")
      assert Ollama.thinking_model?("kimi-k2")
    end

    test "false for plain instruct models" do
      refute Ollama.thinking_model?("llama3.3:70b")
    end
  end
end
