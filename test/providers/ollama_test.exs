defmodule OptimalSystemAgent.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Ollama
  alias OptimalSystemAgent.Providers.ThinkStreamParser
  alias OptimalSystemAgent.Utils.Text

  describe "resolve_request_url/3" do
    test "routes a cloud tag through the signed local daemon when it is available there" do
      assert Ollama.resolve_request_url(
               "https://ollama.com",
               "glm-5.2:cloud",
               ["glm-5.2:cloud", "llama3.2:3b"]
             ) == "http://localhost:11434"
    end

    test "keeps direct cloud routing when the local daemon does not list the tag" do
      assert Ollama.resolve_request_url(
               "https://ollama.com",
               "glm-5.2:cloud",
               ["llama3.2:3b"]
             ) == "https://ollama.com"
    end

    test "does not reroute local-weight models to a different daemon" do
      assert Ollama.resolve_request_url(
               "https://ollama.com",
               "llama3.2:3b",
               ["llama3.2:3b"]
             ) == "https://ollama.com"
    end

    test "preserves an already-local configured URL" do
      assert Ollama.resolve_request_url(
               "http://ollama.internal:11434",
               "glm-5.2:cloud",
               ["glm-5.2:cloud"]
             ) == "http://ollama.internal:11434"
    end
  end

  # ---------------------------------------------------------------------------
  # model_supports_tools?/1
  # ---------------------------------------------------------------------------

  describe "model_supports_tools?/1" do
    test "returns true for qwen3 prefix" do
      assert Ollama.model_supports_tools?("qwen3:14b") == true
      assert Ollama.model_supports_tools?("qwen3:30b-a3b") == true
    end

    test "returns true for qwen2.5 prefix" do
      assert Ollama.model_supports_tools?("qwen2.5:72b") == true
      assert Ollama.model_supports_tools?("qwen2.5-coder:32b") == true
    end

    test "returns true for llama3.1 and llama3.3" do
      assert Ollama.model_supports_tools?("llama3.1:70b") == true
      assert Ollama.model_supports_tools?("llama3.3:70b") == true
    end

    test "returns true for kimi prefix" do
      assert Ollama.model_supports_tools?("kimi-k2.5:latest") == true
    end

    test "returns true for deepseek prefix" do
      assert Ollama.model_supports_tools?("deepseek-coder:33b") == true
    end

    test "returns true for mistral and mixtral" do
      assert Ollama.model_supports_tools?("mistral:7b") == true
      assert Ollama.model_supports_tools?("mixtral:8x7b") == true
    end

    test "returns true for gemma3 prefix" do
      assert Ollama.model_supports_tools?("gemma3:27b") == true
    end

    # These are refused on EVIDENCE, not on unfamiliarity: an embedding model
    # has no chat endpoint at all, and a 1B model cannot hold 23 tool schemas
    # plus a task. An unrecognised name on its own is no longer grounds — see
    # `silent_capability_loss_test.exs`, and `tools_decision/2` for why.
    test "returns false for models that genuinely cannot call tools" do
      assert Ollama.model_supports_tools?("nomic-embed-text:latest") == false
      assert Ollama.model_supports_tools?("all-minilm:latest") == false
      assert Ollama.model_supports_tools?("tinyllama:1b") == false
    end

    test "returns false for tiny models with :1. version tag" do
      assert Ollama.model_supports_tools?("qwen3:1.7b") == false
    end

    test "returns false for :3b tagged models" do
      assert Ollama.model_supports_tools?("llama3.1:3b") == false
    end

    test "is case-insensitive" do
      assert Ollama.model_supports_tools?("QWEN3:14B") == true
      assert Ollama.model_supports_tools?("LLaMA3.3:70b") == true
    end

    test "returns false for empty string" do
      assert Ollama.model_supports_tools?("") == false
    end
  end

  # ---------------------------------------------------------------------------
  # thinking_model?/1
  # ---------------------------------------------------------------------------

  describe "thinking_model?/1" do
    test "returns true for kimi models" do
      assert Ollama.thinking_model?("kimi-k2.5:latest") == true
      assert Ollama.thinking_model?("kimi:latest") == true
    end

    test "returns true for model names containing 'thinking'" do
      assert Ollama.thinking_model?("qwen3-thinking:14b") == true
      assert Ollama.thinking_model?("deepseek-thinking-v2:32b") == true
    end

    test "returns false for regular models" do
      assert Ollama.thinking_model?("llama3.1:70b") == false
      assert Ollama.thinking_model?("qwen3:14b") == false
      assert Ollama.thinking_model?("mistral:7b") == false
    end

    test "is case-insensitive" do
      assert Ollama.thinking_model?("KIMI:latest") == true
      assert Ollama.thinking_model?("Qwen3-THINKING:32b") == true
    end
  end

  # ---------------------------------------------------------------------------
  # split_ndjson/1
  # ---------------------------------------------------------------------------

  describe "split_ndjson/1" do
    test "splits single complete JSON line with newline" do
      data = ~s|{"message":{"content":"hello"}}\n|
      {complete, remainder} = Ollama.split_ndjson(data)
      assert complete == [~s|{"message":{"content":"hello"}}|]
      assert remainder == ""
    end

    test "splits multiple complete lines" do
      data = ~s|{"message":{"content":"a"}}\n{"message":{"content":"b"}}\n|
      {complete, remainder} = Ollama.split_ndjson(data)
      assert length(complete) == 2
      assert remainder == ""
    end

    test "retains partial line as remainder" do
      data = ~s|{"message":{"content":"a"}}\n{"partial|
      {complete, remainder} = Ollama.split_ndjson(data)
      assert complete == [~s|{"message":{"content":"a"}}|]
      assert remainder == ~s|{"partial|
    end

    test "returns empty complete list when data has no newline" do
      data = ~s|{"partial json|
      {complete, remainder} = Ollama.split_ndjson(data)
      assert complete == []
      assert remainder == data
    end

    test "filters out blank lines" do
      data = "\n\n{\"message\":{\"content\":\"x\"}}\n\n"
      {complete, _} = Ollama.split_ndjson(data)
      # Blank lines are filtered, one real line
      assert length(complete) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # process_ndjson_line/3
  # ---------------------------------------------------------------------------

  describe "process_ndjson_line/3" do
    defp make_acc, do: %{buffer: "", content: "", tool_calls: []}

    test "emits :text_delta for content field and accumulates" do
      tokens = []
      cb = fn event -> send(self(), {:cb, event}) end
      acc = make_acc()

      line = ~s|{"message":{"content":"hello "}}|
      new_acc = Ollama.process_ndjson_line(line, cb, acc)

      assert new_acc.content == "hello "
      assert_received {:cb, {:text_delta, "hello "}}
    end

    test "accumulates multiple content deltas in order" do
      cb = fn event -> send(self(), {:cb, event}) end
      acc = make_acc()

      acc = Ollama.process_ndjson_line(~s|{"message":{"content":"foo"}}|, cb, acc)
      acc = Ollama.process_ndjson_line(~s|{"message":{"content":" bar"}}|, cb, acc)

      assert acc.content == "foo bar"
      assert_received {:cb, {:text_delta, "foo"}}
      assert_received {:cb, {:text_delta, " bar"}}
    end

    test "emits :thinking_delta for thinking field" do
      cb = fn event -> send(self(), {:cb, event}) end
      acc = make_acc()

      line = ~s|{"message":{"thinking":"I need to think..."}}|
      new_acc = Ollama.process_ndjson_line(line, cb, acc)

      # thinking deltas don't accumulate into content
      assert new_acc.content == ""
      assert_received {:cb, {:thinking_delta, "I need to think..."}}
    end

    test "captures tool_calls from stream chunk" do
      cb = fn _event -> :ok end
      acc = make_acc()

      line =
        Jason.encode!(%{
          "message" => %{
            "tool_calls" => [
              %{
                "id" => "tc_1",
                "function" => %{"name" => "file_read", "arguments" => %{"path" => "/tmp/x"}}
              }
            ]
          }
        })

      new_acc = Ollama.process_ndjson_line(line, cb, acc)
      assert length(new_acc.tool_calls) == 1
      [tc] = new_acc.tool_calls
      assert tc.name == "file_read"
      assert tc.arguments == %{"path" => "/tmp/x"}
    end

    test "appends multiple tool calls across chunks" do
      cb = fn _event -> :ok end

      line1 =
        Jason.encode!(%{
          "message" => %{
            "tool_calls" => [
              %{"id" => "a", "function" => %{"name" => "tool_a", "arguments" => %{}}}
            ]
          }
        })

      line2 =
        Jason.encode!(%{
          "message" => %{
            "tool_calls" => [
              %{"id" => "b", "function" => %{"name" => "tool_b", "arguments" => %{"x" => 1}}}
            ]
          }
        })

      acc = make_acc()
      acc = Ollama.process_ndjson_line(line1, cb, acc)
      acc = Ollama.process_ndjson_line(line2, cb, acc)

      assert length(acc.tool_calls) == 2
      names = Enum.map(acc.tool_calls, & &1.name)
      assert "tool_a" in names
      assert "tool_b" in names
    end

    test "ignores malformed JSON without crashing" do
      cb = fn event -> send(self(), {:cb, event}) end
      acc = make_acc()

      new_acc = Ollama.process_ndjson_line("not json at all {{{", cb, acc)
      assert new_acc == acc
      refute_received {:cb, _}
    end

    test "ignores empty content field without emitting callback" do
      cb = fn event -> send(self(), {:cb, event}) end
      acc = make_acc()

      new_acc = Ollama.process_ndjson_line(~s|{"message":{"content":""}}|, cb, acc)
      assert new_acc == acc
      refute_received {:cb, _}
    end

    test "a done chunk emits no callback and captures only the stop reason" do
      # This used to assert `new_acc == acc` — that the done chunk changed
      # NOTHING. That assertion encoded the defect: `done_reason` is Ollama's
      # terminal stop reason, and dropping it is what let a generation cut off
      # at `num_predict` be delivered as a finished answer. See
      # `Providers.StopReason` and
      # `test/providers/provider_truncation_reporting_test.exs`.
      #
      # What the test was actually protecting — no callback fires, no content
      # or tool calls are invented — still holds.
      cb = fn event -> send(self(), {:cb, event}) end
      acc = make_acc()

      new_acc = Ollama.process_ndjson_line(~s|{"done":true,"done_reason":"stop"}|, cb, acc)

      assert new_acc.stop_reason == "stop"
      assert Map.delete(new_acc, :stop_reason) == Map.delete(acc, :stop_reason)
      refute_received {:cb, _}
    end
  end

  # ---------------------------------------------------------------------------
  # pick_best_model/1
  # ---------------------------------------------------------------------------

  describe "pick_best_model/1" do
    defp gb(n), do: round(n * 1_000_000_000)

    test "picks the largest tool-capable model" do
      models = [
        %{name: "qwen3:14b", size: gb(8.5), modified: nil},
        %{name: "qwen3:72b", size: gb(45), modified: nil},
        %{name: "llama3.1:8b", size: gb(5), modified: nil}
      ]

      best = Ollama.pick_best_model(models)
      assert best.name == "qwen3:72b"
    end

    test "falls back to largest model >= 4GB when none are tool-capable" do
      models = [
        %{name: "phi3:mini", size: gb(2), modified: nil},
        %{name: "orca2:13b", size: gb(8), modified: nil},
        %{name: "tinyllama:1b", size: gb(0.6), modified: nil}
      ]

      best = Ollama.pick_best_model(models)
      assert best.name == "orca2:13b"
    end

    test "returns nil when all models are below 4GB and none are tool-capable" do
      models = [
        %{name: "phi3:mini", size: gb(2), modified: nil},
        %{name: "tinyllama:1b", size: gb(0.6), modified: nil}
      ]

      best = Ollama.pick_best_model(models)
      assert best == nil
    end

    test "returns nil for empty model list" do
      assert Ollama.pick_best_model([]) == nil
    end

    test "prefers tool-capable model over larger non-tool-capable" do
      models = [
        %{name: "unknown-giant:200b", size: gb(120), modified: nil},
        %{name: "qwen3:14b", size: gb(9), modified: nil}
      ]

      # unknown-giant doesn't match @tool_capable_prefixes, so qwen3 is preferred
      # (qwen3 IS tool-capable and >= 7GB minimum)
      best = Ollama.pick_best_model(models)
      assert best.name == "qwen3:14b"
    end
  end

  # ---------------------------------------------------------------------------
  # Utils.Text.strip_thinking_tokens/1
  # ---------------------------------------------------------------------------

  describe "Utils.Text.strip_thinking_tokens/1" do
    test "strips <think> block" do
      input = "<think>\nThis is reasoning\n</think>\nActual answer."
      assert Text.strip_thinking_tokens(input) == "Actual answer."
    end

    test "strips <reasoning> block" do
      input = "<reasoning>internal thought</reasoning>Response text."
      assert Text.strip_thinking_tokens(input) == "Response text."
    end

    test "strips <|start|>...<|end|> block" do
      input = "<|start|>thinks deeply<|end|>Here is the answer."
      assert Text.strip_thinking_tokens(input) == "Here is the answer."
    end

    test "returns plain text unchanged" do
      input = "This is just a normal response."
      assert Text.strip_thinking_tokens(input) == input
    end

    test "returns empty string for nil" do
      assert Text.strip_thinking_tokens(nil) == ""
    end

    test "handles multiline thinking block" do
      input = """
      <think>
      Step 1: consider A
      Step 2: consider B
      Therefore: C
      </think>
      Final answer: C
      """

      result = Text.strip_thinking_tokens(input)
      assert result == "Final answer: C"
    end

    test "handles content with no thinking block after stripping" do
      input = "<think>all thinking, no output</think>"
      assert Text.strip_thinking_tokens(input) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # list_models/1 — error handling (no live server needed)
  # ---------------------------------------------------------------------------

  describe "list_models/1 error handling" do
    test "returns {:error, _} when server is unreachable" do
      # Port 1 is reserved and never listening — guaranteed connection refused
      assert {:error, _reason} = Ollama.list_models("http://localhost:1")
    end

    test "returns {:error, _} for malformed URL" do
      assert {:error, _reason} = Ollama.list_models("not-a-url")
    end
  end

  # ---------------------------------------------------------------------------
  # auto_detect_model/0 — graceful no-server behavior
  # ---------------------------------------------------------------------------

  describe "auto_detect_model/0" do
    test "returns :ok when no Ollama server is running" do
      # Point at a port that's not listening — should not raise or crash
      Application.put_env(:optimal_system_agent, :ollama_url, "http://localhost:1")

      result = Ollama.auto_detect_model()
      assert result == :ok
    after
      Application.delete_env(:optimal_system_agent, :ollama_url)
    end

    test "returns :ok when explicit model is configured (skips detection)" do
      Application.put_env(:optimal_system_agent, :default_model, "llama3.1:70b")

      result = Ollama.auto_detect_model()
      assert result == :ok
    after
      Application.delete_env(:optimal_system_agent, :default_model)
    end
  end

  # ---------------------------------------------------------------------------
  # name/0 and default_model/0 — behaviour contracts
  # ---------------------------------------------------------------------------

  describe "provider behaviour" do
    test "name/0 returns :ollama" do
      assert Ollama.name() == :ollama
    end

    test "default_model/0 returns a non-empty string" do
      model = Ollama.default_model()
      assert is_binary(model) and model != ""
    end
  end

  # ---------------------------------------------------------------------------
  # process_ndjson_line/3 — inline <think> reasoning must never leak into the
  # visible stream (regression: glm-5.2:cloud inlines reasoning as <think>…).
  # ---------------------------------------------------------------------------

  describe "streaming reasoning-tag stripping" do
    defp collect(line, acc) do
      me = self()
      cb = fn ev -> send(me, ev) end
      Ollama.process_ndjson_line(line, cb, acc)
    end

    defp drain do
      Enum.reduce_while(1..100, {"", ""}, fn _, {vis, think} ->
        receive do
          {:text_delta, t} -> {:cont, {vis <> t, think}}
          {:thinking_delta, t} -> {:cont, {vis, think <> t}}
        after
          0 -> {:halt, {vis, think}}
        end
      end)
    end

    test "routes <think> content to thinking channel, keeps visible clean" do
      acc = %{
        buffer: "",
        content: "",
        tool_calls: [],
        usage: %{},
        think: ThinkStreamParser.new()
      }

      acc = collect(~s({"message":{"content":"<think>reasoning</think>"}}), acc)
      _acc = collect(~s({"message":{"content":"Hello"}}), acc)

      {visible, thinking} = drain()

      assert visible == "Hello"
      refute visible =~ "<think>"
      assert thinking == "reasoning"
    end

    test "handles a <think> tag split across two chunks" do
      acc = %{
        buffer: "",
        content: "",
        tool_calls: [],
        usage: %{},
        think: ThinkStreamParser.new()
      }

      acc = collect(~s({"message":{"content":"<thi"}}), acc)
      _acc = collect(~s({"message":{"content":"nk>secret</think>answer"}}), acc)

      {visible, thinking} = drain()

      assert visible == "answer"
      refute visible =~ "think"
      assert thinking == "secret"
    end
  end
end
