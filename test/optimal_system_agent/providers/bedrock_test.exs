defmodule OptimalSystemAgent.Providers.BedrockTest do
  @moduledoc """
  The Bedrock transport, over the Converse API.

  The tests that matter here are the shape translations, because Bedrock
  rejects a malformed conversation with a `ValidationException` that names
  neither the message nor the field — so a mistake in this mapping is opaque
  at runtime and obvious only here.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Bedrock

  @env ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
          AWS_REGION AWS_DEFAULT_REGION AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
          AWS_BEARER_TOKEN_BEDROCK)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    dir = Path.join(System.tmp_dir!(), "osa-bedrock-tx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)
    System.put_env("AWS_SHARED_CREDENTIALS_FILE", Path.join(dir, "credentials"))
    System.put_env("AWS_CONFIG_FILE", Path.join(dir, "config"))
    System.put_env("AWS_ACCESS_KEY_ID", "AKIAEXAMPLE")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    System.put_env("AWS_REGION", "us-east-1")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")

      for k <- [:bedrock_req_options, :bedrock_model, :bedrock_api_key] do
        Application.delete_env(:optimal_system_agent, k)
      end

      File.rm_rf(dir)
    end)

    :ok
  end

  # Captures the request Bedrock would have sent, decoded, so assertions are
  # about the body AWS receives rather than about intermediate structs.
  defp stub(status \\ 200, response \\ nil) do
    {:ok, seen} = Agent.start_link(fn -> [] end)

    body =
      response ||
        %{
          "output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => "hi"}]}},
          "stopReason" => "end_turn",
          "usage" => %{"inputTokens" => 11, "outputTokens" => 7, "totalTokens" => 18}
        }

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      Agent.update(seen, fn acc ->
        [
          %{
            host: conn.host,
            path: conn.request_path,
            headers: conn.req_headers,
            body: Jason.decode!(raw)
          }
          | acc
        ]
      end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    Application.put_env(:optimal_system_agent, :bedrock_req_options, plug: plug, retry: false)
    seen
  end

  defp last(agent), do: Agent.get(agent, &List.first/1)

  describe "endpoint and signing" do
    test "posts Converse on the runtime plane with a SigV4 authorization" do
      seen = stub()

      assert {:ok, _} = Bedrock.chat([%{role: "user", content: "hello"}])

      req = last(seen)
      assert req.host == "bedrock-runtime.us-east-1.amazonaws.com"
      assert req.path =~ "/converse"

      auth = header(req, "authorization")
      assert auth =~ "AWS4-HMAC-SHA256"
      # Both planes sign as `bedrock`, NOT `bedrock-runtime`. A mismatch here
      # is a SignatureDoesNotMatch with no useful diagnostic.
      assert auth =~ "/us-east-1/bedrock/aws4_request"
    end

    test "sends the model id in the path with its colon intact" do
      seen = stub()

      assert {:ok, _} =
               Bedrock.chat([%{role: "user", content: "x"}],
                 model: "anthropic.claude-sonnet-4-5-20250929-v1:0"
               )

      assert last(seen).path ==
               "/model/anthropic.claude-sonnet-4-5-20250929-v1:0/converse"
    end

    test "an explicit bearer key beats the auto-discovered credential chain" do
      # Explicit user intent wins. Inverting this bills a different AWS
      # account than the one the user named.
      Application.put_env(:optimal_system_agent, :bedrock_api_key, "bedrock-key-abc")
      seen = stub()

      assert {:ok, _} = Bedrock.chat([%{role: "user", content: "x"}])

      assert header(last(seen), "authorization") == "Bearer bedrock-key-abc"
    end

    test "a bearer key with no region says which field is missing" do
      Application.put_env(:optimal_system_agent, :bedrock_api_key, "k")
      System.delete_env("AWS_REGION")
      stub()

      assert {:error, message} = Bedrock.chat([%{role: "user", content: "x"}])
      assert message =~ "no global endpoint"
      assert message =~ "AWS_REGION"
    end

    test "no credentials at all reports the whole chain, not a bare failure" do
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")
      stub()

      assert {:error, message} = Bedrock.chat([%{role: "user", content: "x"}])
      assert message =~ "environment"
      assert message =~ "aws configure"
    end
  end

  describe "request shaping" do
    test "system prompts move to the top-level field Converse requires" do
      seen = stub()

      assert {:ok, _} =
               Bedrock.chat([
                 %{role: "system", content: "be terse"},
                 %{role: "user", content: "hi"}
               ])

      body = last(seen).body
      assert body["system"] == [%{"text" => "be terse"}]
      # Leaving a system message in the list is rejected outright, not ignored.
      assert body["messages"] == [%{"role" => "user", "content" => [%{"text" => "hi"}]}]
    end

    test "no system prompt means no system key at all" do
      seen = stub()
      assert {:ok, _} = Bedrock.chat([%{role: "user", content: "hi"}])
      refute Map.has_key?(last(seen).body, "system")
    end

    test "assistant tool calls become toolUse blocks" do
      seen = stub()

      messages = [
        %{role: "user", content: "weather?"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "t1", name: "get_weather", arguments: %{"city" => "Berlin"}}]
        },
        %{role: "tool", tool_call_id: "t1", content: "17C"}
      ]

      assert {:ok, _} = Bedrock.chat(messages)

      [_user, assistant, tool_result] = last(seen).body["messages"]

      assert assistant["role"] == "assistant"

      assert assistant["content"] == [
               %{
                 "toolUse" => %{
                   "toolUseId" => "t1",
                   "name" => "get_weather",
                   "input" => %{"city" => "Berlin"}
                 }
               }
             ]

      assert tool_result["role"] == "user"

      assert tool_result["content"] == [
               %{
                 "toolResult" => %{
                   "toolUseId" => "t1",
                   "content" => [%{"text" => "17C"}]
                 }
               }
             ]
    end

    test "parallel tool results are merged into ONE user turn" do
      # Converse requires strictly alternating roles. OSA emits one message
      # per tool result, so without merging, parallel tool use never works —
      # and the error AWS returns says nothing about tools.
      seen = stub()

      messages = [
        %{role: "user", content: "go"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{id: "a", name: "one", arguments: %{}},
            %{id: "b", name: "two", arguments: %{}}
          ]
        },
        %{role: "tool", tool_call_id: "a", content: "1"},
        %{role: "tool", tool_call_id: "b", content: "2"}
      ]

      assert {:ok, _} = Bedrock.chat(messages)

      roles = Enum.map(last(seen).body["messages"], & &1["role"])
      assert roles == ["user", "assistant", "user"]

      [_, _, merged] = last(seen).body["messages"]
      assert length(merged["content"]) == 2
    end

    test "an assistant turn with only tool calls still carries a content block" do
      seen = stub()

      assert {:ok, _} =
               Bedrock.chat([
                 %{role: "user", content: "go"},
                 %{role: "assistant", content: "", tool_calls: [%{id: "a", name: "n", arguments: %{}}]}
               ])

      [_, assistant] = last(seen).body["messages"]
      refute assistant["content"] == []
    end

    test "tools are translated into toolSpec entries from the OpenAI shape" do
      seen = stub()

      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "search",
            "description" => "look things up",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        }
      ]

      assert {:ok, _} = Bedrock.chat([%{role: "user", content: "x"}], tools: tools)

      assert last(seen).body["toolConfig"] == %{
               "tools" => [
                 %{
                   "toolSpec" => %{
                     "name" => "search",
                     "description" => "look things up",
                     "inputSchema" => %{"json" => %{"type" => "object", "properties" => %{}}}
                   }
                 }
               ]
             }
    end

    test "inference options are only sent when supplied" do
      seen = stub()
      assert {:ok, _} = Bedrock.chat([%{role: "user", content: "x"}])
      refute Map.has_key?(last(seen).body, "inferenceConfig")

      assert {:ok, _} =
               Bedrock.chat([%{role: "user", content: "x"}], max_tokens: 100, temperature: 0.2)

      assert last(seen).body["inferenceConfig"] == %{"maxTokens" => 100, "temperature" => 0.2}
    end

    test "list content is flattened to text" do
      seen = stub()

      assert {:ok, _} =
               Bedrock.chat([%{role: "user", content: [%{type: "text", text: "a"}, %{type: "text", text: "b"}]}])

      assert last(seen).body["messages"] == [%{"role" => "user", "content" => [%{"text" => "ab"}]}]
    end
  end

  describe "response parsing" do
    test "extracts text, tool calls and usage together" do
      stub(200, %{
        "output" => %{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"text" => "checking"},
              %{"toolUse" => %{"toolUseId" => "t9", "name" => "f", "input" => %{"a" => 1}}}
            ]
          }
        },
        "usage" => %{"inputTokens" => 3, "outputTokens" => 4, "totalTokens" => 7}
      })

      assert {:ok, result} = Bedrock.chat([%{role: "user", content: "x"}])
      assert result.content == "checking"
      assert result.tool_calls == [%{id: "t9", name: "f", arguments: %{"a" => 1}}]
      assert result.usage == %{prompt_tokens: 3, completion_tokens: 4, total_tokens: 7}
    end

    test "usage OSA was not given is reported as zero, not invented" do
      stub(200, %{"output" => %{"message" => %{"content" => [%{"text" => "x"}]}}})

      assert {:ok, %{usage: %{total_tokens: 0}}} = Bedrock.chat([%{role: "user", content: "x"}])
    end
  end

  describe "error mapping" do
    test "a 403 points at model access, not at the credential" do
      # The credential already proved itself at connect time. Bedrock gates
      # each model separately, per region.
      stub(403, %{"message" => "You don't have access to the model with the specified model ID."})

      assert {:error, message} = Bedrock.chat([%{role: "user", content: "x"}])
      assert message =~ "Model access"
      refute message =~ "credentials"
    end

    test "a 400 suggests the cross-region inference profile form" do
      stub(400, %{"message" => "Invocation of model ID ... with on-demand throughput isn't supported"})

      assert {:error, message} = Bedrock.chat([%{role: "user", content: "x"}])
      assert message =~ "inference profile"
    end

    test "a 429 is named as throttling" do
      stub(429, %{"message" => "Too many requests"})
      assert {:error, message} = Bedrock.chat([%{role: "user", content: "x"}])
      assert message =~ "throttling"
    end
  end

  describe "defaults" do
    test "the default model is a cross-region inference profile" do
      # Newer Bedrock models reject a bare model id for on-demand use with a
      # ValidationException that reads like the model does not exist.
      assert Bedrock.default_model() =~ ~r/^(us|eu|apac)\./
    end

    test "an unset BEDROCK_MODEL does not resolve the model to nil" do
      # `config/runtime.exs` sets the key to `System.get_env(...)`, which is
      # nil when unset — and a key that EXISTS with a nil value never reaches
      # `Application.get_env/3`'s default argument.
      Application.put_env(:optimal_system_agent, :bedrock_model, nil)
      assert is_binary(Bedrock.default_model())
    end

    test "streaming is deliberately absent so the Registry falls back to sync" do
      # A half-parsed vnd.amazon.eventstream frame produces truncated or
      # duplicated model output, which is indistinguishable from the model
      # behaving badly. Sync-only is the honest interim state.
      refute function_exported?(Bedrock, :chat_stream, 3)
    end
  end

  defp header(req, name) do
    Enum.find_value(req.headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end
end
