defmodule OptimalSystemAgent.Providers.OllamaContextFloorTest do
  @moduledoc """
  A window too small for the request must fail loudly, not truncate quietly.

  OSA is ahead of most harnesses on sizing: `build_options/3` computes `num_ctx`
  from prompt + predict + slack, and `Registry.effective_context_window/2`
  shares that number with `Agent.Context` so the budget and the daemon agree.
  What was missing is the bottom end. `round_up_ctx/1` floors at 4096 and the
  result is then `min(max_ctx)`-ed, so a `:ollama_num_ctx` of 2048 was simply
  requested — and Ollama honours it by LEFT-TRUNCATING the prompt, discarding
  the system prompt and the earlier turns with no error anywhere. The visible
  symptom is a model that has forgotten its instructions, which reads as a
  model-quality problem rather than a configuration one.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Ollama

  @model "test-tiny-model:latest"

  @tools [
    %{
      "type" => "function",
      "function" => %{"name" => "file_read", "description" => "read", "parameters" => %{}}
    }
  ]

  setup do
    prev_ctx = Application.fetch_env(:optimal_system_agent, :ollama_num_ctx)
    prev_max = Application.fetch_env(:optimal_system_agent, :max_context_tokens)

    on_exit(fn ->
      restore(:ollama_num_ctx, prev_ctx)
      restore(:max_context_tokens, prev_max)
    end)

    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:optimal_system_agent, key, v)
  defp restore(key, :error), do: Application.delete_env(:optimal_system_agent, key)

  describe "context_floor_error/2" do
    test "a too-small configured window is refused, naming the setting to change" do
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 2048)

      assert {:error, message} = Ollama.context_floor_error(@model, tools: @tools)

      assert message =~ "2048",
             "the message must state the window actually in force: #{message}"

      assert message =~ "ollama_num_ctx",
             "a fail-fast that does not name the knob is just a different silence: " <>
               message

      assert message =~ "truncate",
             "the user needs to know WHY it was refused, not just that it was: " <> message
    end

    test "a workable window passes" do
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 32_768)
      assert :ok = Ollama.context_floor_error(@model, tools: @tools)
    end

    test "a toolless turn is never blocked — a small window is legitimate there" do
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 2048)

      assert :ok = Ollama.context_floor_error(@model, [])
      assert :ok = Ollama.context_floor_error(@model, tools: nil)
      assert :ok = Ollama.context_floor_error(@model, tools: [])
    end
  end

  describe "the check is wired into the request path" do
    test "chat/2 refuses before opening a connection" do
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 1024)

      # Point at a port nothing is listening on: if the guard did not fire, the
      # failure would be a connection error rather than the context message.
      prev_url = Application.fetch_env(:optimal_system_agent, :ollama_url)
      Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:1")
      on_exit(fn -> restore(:ollama_url, prev_url) end)

      assert {:error, message} =
               Ollama.chat([%{role: "user", content: "hi"}], model: @model, tools: @tools)

      assert message =~ "context window",
             "expected the fail-fast, got what looks like a network error: " <> message

      refute message =~ "connection failed", message
    end

    test "chat_stream/3 refuses too" do
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 1024)

      prev_url = Application.fetch_env(:optimal_system_agent, :ollama_url)
      Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:1")
      on_exit(fn -> restore(:ollama_url, prev_url) end)

      assert {:error, message} =
               Ollama.chat_stream(
                 [%{role: "user", content: "hi"}],
                 fn _ -> :ok end,
                 model: @model,
                 tools: @tools
               )

      assert message =~ "context window", message
    end
  end
end
