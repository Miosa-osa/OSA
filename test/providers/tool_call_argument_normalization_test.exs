defmodule OptimalSystemAgent.Providers.ToolCallArgumentNormalizationTest do
  @moduledoc """
  A tool call's `arguments` must be an OBJECT by the time it reaches any wire.

  Every provider emits it verbatim: Anthropic as `tool_use.input`, Ollama and
  Google as a nested map, OpenAI-compatible providers as a JSON-encoded string
  of it. None of them accept a bare string, and each rejects it differently:

      anthropic → 400 messages.N.content.M.tool_use.input: Input should be an object
      ollama    → 400 {"error":"Value looks like object, but can't find closing '}' symbol"}

  `Agent.Compactor` used to strip heavy arguments by replacing the map with the
  STRING `"[args stripped]"`. Because compacted history is persisted to
  `~/.osa/sessions/<id>.json`, one compaction poisoned the session permanently:
  every later turn 400'd on the primary provider, then 400'd again on every
  provider in the fallback chain, so switching models could not clear it. The
  user-visible error was always the LAST fallback's — an Ollama parse error
  reported while the session was configured for Anthropic.

  Two guards, both required:

    * the Compactor must strip to a valid empty object, and
    * the provider boundary must coerce a non-object `arguments` anyway, so the
      sessions already carrying the placeholder on disk heal on next load.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Providers
  alias OptimalSystemAgent.Providers.Ollama
  alias OptimalSystemAgent.Providers.Registry

  defp args_of(messages) do
    messages
    |> Enum.flat_map(fn msg -> Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") || [] end)
    |> Enum.map(fn tc -> tc[:arguments] || tc["arguments"] end)
  end

  # ---------------------------------------------------------------------------
  # Registry.normalize_outbound_messages/2 — the provider boundary
  # ---------------------------------------------------------------------------

  describe "normalize_outbound_messages/2" do
    test "coerces the compactor's placeholder string into an empty object" do
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "toolu_1", name: "dir_list", arguments: "[args stripped]"}]
        }
      ]

      for target <- [Providers.Anthropic, Providers.Ollama, {:compat, :openai}] do
        assert args_of(Registry.normalize_outbound_messages(messages, target)) == [%{}],
               "expected an object for target #{inspect(target)}"
      end
    end

    test "decodes genuinely stringified JSON object arguments instead of discarding them" do
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{id: "toolu_1", name: "dir_list", arguments: ~s({"path":"/Users/jarvis/.osa"})}
          ]
        }
      ]

      assert args_of(Registry.normalize_outbound_messages(messages, Providers.Anthropic)) == [
               %{"path" => "/Users/jarvis/.osa"}
             ]
    end

    test "coerces truncated JSON, nil, and non-object JSON to an empty object" do
      for bad <- [~s({"path":"/Users/jarv), nil, "[1,2,3]", ~s("just a string"), 42] do
        messages = [
          %{role: "assistant", content: "", tool_calls: [%{id: "t", name: "x", arguments: bad}]}
        ]

        assert args_of(Registry.normalize_outbound_messages(messages, Providers.Anthropic)) == [
                 %{}
               ],
               "expected an object for #{inspect(bad)}"
      end
    end

    test "normalizes string-keyed tool_calls on string-keyed messages" do
      messages = [
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{"id" => "toolu_1", "name" => "dir_list", "arguments" => "[args stripped]"}
          ]
        }
      ]

      assert args_of(Registry.normalize_outbound_messages(messages, Providers.Ollama)) == [%{}]
    end

    test "leaves valid object arguments untouched" do
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "t", name: "dir_list", arguments: %{"path" => "."}}]
        }
      ]

      assert Registry.normalize_outbound_messages(messages, Providers.Anthropic) == messages
    end

    test "leaves messages without tool_calls untouched" do
      messages = [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]
      assert Registry.normalize_outbound_messages(messages, Providers.Anthropic) == messages
    end
  end

  # ---------------------------------------------------------------------------
  # Ollama.format_messages/1 — string-keyed tool_calls must not raise
  # ---------------------------------------------------------------------------

  describe "Ollama.format_messages/1 with rehydrated (string-keyed) tool_calls" do
    test "does not raise KeyError on a string-keyed tool call" do
      # Exactly what a session reloaded from ~/.osa/sessions/<id>.json yields:
      # the message keys are atomized, the nested tool_call maps are not.
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              "id" => "toolu_01Mz7RnAHi9WMG6mkYfcLoC8",
              "name" => "dir_list",
              "arguments" => %{"path" => "/Users/jarvis/.osa"}
            }
          ]
        }
      ]

      [formatted] = Ollama.format_messages(messages)

      assert [call] = formatted["tool_calls"]
      assert call["id"] == "toolu_01Mz7RnAHi9WMG6mkYfcLoC8"
      assert call["function"]["name"] == "dir_list"
      assert call["function"]["arguments"] == %{"path" => "/Users/jarvis/.osa"}
    end

    test "still formats atom-keyed tool calls" do
      messages = [
        %{
          role: "assistant",
          content: "run",
          tool_calls: [%{id: "t1", name: "dir_list", arguments: %{"path" => "."}}]
        }
      ]

      [formatted] = Ollama.format_messages(messages)
      assert [%{"id" => "t1", "function" => %{"name" => "dir_list"}}] = formatted["tool_calls"]
    end
  end

  # ---------------------------------------------------------------------------
  # Compactor — the origin of the corruption
  # ---------------------------------------------------------------------------

  describe "Compactor arg stripping" do
    test "strips heavy arguments to a valid empty object, not a string" do
      Application.put_env(:optimal_system_agent, :max_context_tokens, 800)
      Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)
      Application.put_env(:optimal_system_agent, :compaction_aggressive, 0.0)
      Application.put_env(:optimal_system_agent, :compaction_emergency, 1.1)

      long_args = %{"data" => String.duplicate("argument data ", 200)}

      messages =
        Enum.map(1..5, fn i ->
          %{role: "user", content: String.duplicate("word ", 20) <> "#{i}"}
        end) ++
          [
            %{
              role: "assistant",
              content: "running tool",
              tool_calls: [%{id: "t1", name: "shell_execute", arguments: long_args}]
            }
          ]

      result = Compactor.maybe_compact(messages)

      stripped =
        result
        |> Enum.flat_map(&(Map.get(&1, :tool_calls) || []))
        |> Enum.map(&(&1[:arguments] || &1["arguments"]))

      assert stripped != [], "expected the tool message to survive compaction"

      for args <- stripped do
        assert is_map(args), "arguments must stay an object, got: #{inspect(args)}"
      end
    after
      Application.delete_env(:optimal_system_agent, :max_context_tokens)
      Application.delete_env(:optimal_system_agent, :compaction_warn)
      Application.delete_env(:optimal_system_agent, :compaction_aggressive)
      Application.delete_env(:optimal_system_agent, :compaction_emergency)
    end

    test "stripping a string-keyed tool call does not leave a mixed-key map" do
      msg = %{
        role: "assistant",
        content: "",
        tool_calls: [%{"id" => "t1", "name" => "x", "arguments" => %{"big" => "payload"}}]
      }

      [call] = Compactor.strip_tool_args(msg).tool_calls

      refute Map.has_key?(call, :arguments),
             "an atom :arguments alongside \"arguments\" makes the stripped value unreachable"

      assert call["arguments"] == %{}
    end
  end
end
