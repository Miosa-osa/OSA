defmodule OptimalSystemAgent.Providers.StructuredContentNormalizationTest do
  @moduledoc """
  Anthropic-shaped structured content must never reach a provider that cannot
  read it.

  `Agent.Context.build_system_message/4` emits the system prompt as an ARRAY of
  `cache_control`-marked content blocks when (and only when) the provider is
  `:anthropic` — that is the prompt-cache fix. `MessageHandler`/`ToolExecutor`
  emit `user`/`tool` turns as `text` + `image` block arrays whenever an image is
  attached, for every provider.

  Every non-Anthropic provider module does `to_string(content)` somewhere
  (`openai_compat.ex`, `ollama.ex`, `cohere.ex`, `replicate.ex`, `google.ex`),
  and a list has no `String.Chars` implementation — so a block list reaching one
  of them raises `ArgumentError: cannot convert the given list to a string`.

  `Loop.LLMClient` hands `FallbackChain` the SAME already-built messages without
  rebuilding context, so an Anthropic 5xx used to fail over into a guaranteed
  ArgumentError on every remaining provider — each swallowed by FallbackChain's
  `rescue` and reported as `{:error, "All providers failed: …"}`. The fallback
  path was dead exactly when it was needed. The end-to-end test at the bottom is
  the one that catches that.

  The wire-body tests assert BYTE-IDENTITY between the block-shaped request and
  the equivalent flat-string request: flattening must not silently rewrite the
  prompt every non-Anthropic provider was already receiving.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers
  alias OptimalSystemAgent.Providers.FallbackChain
  alias OptimalSystemAgent.Providers.Registry

  # High ports — the low ones linger between runs.
  @port_base 11_601

  # The exact shape `Context.build_system_message/4` emits for :anthropic.
  @static_base "STATIC BASE: you are OSA."
  @world_state "WORLD STATE: tool doctrine and AGENTS.md."
  @volatile "VOLATILE: - Timestamp: 2026-08-02T00:00:00Z"

  defp block_system do
    [
      %{type: "text", text: @static_base, cache_control: %{type: "ephemeral"}},
      %{type: "text", text: @world_state, cache_control: %{type: "ephemeral"}},
      %{type: "text", text: @volatile}
    ]
  end

  # What `Context.build_system_message/4`'s non-Anthropic branch produces for
  # the same three pieces. This is the byte-for-byte target.
  defp flat_system, do: Enum.join([@static_base, @world_state, @volatile], "\n\n")

  defp block_messages,
    do: [%{role: "system", content: block_system()}, %{role: "user", content: "hi"}]

  defp flat_messages,
    do: [%{role: "system", content: flat_system()}, %{role: "user", content: "hi"}]

  # ── The dispatch-time decision ─────────────────────────────────────────────

  describe "normalize_message_content/2" do
    test "Anthropic is passed through untouched, cache_control and all" do
      messages = block_messages()

      assert Registry.normalize_message_content(messages, Providers.Anthropic) === messages
    end

    test "every other dispatch target is flattened to a plain string" do
      targets = [
        Providers.Ollama,
        Providers.Google,
        Providers.Cohere,
        Providers.Replicate,
        {:compat, :openai},
        {:compat, :groq},
        {:compat, :openrouter}
      ]

      for target <- targets do
        [system | _] = Registry.normalize_message_content(block_messages(), target)

        assert is_binary(system.content),
               "#{inspect(target)} still receives list content and will raise ArgumentError"

        assert system.content == flat_system(),
               "#{inspect(target)} received a prompt that differs from the pre-cache-fix string"
      end
    end

    test "flattening drops cache_control entirely — it is an Anthropic-only field" do
      [system | _] = Registry.normalize_message_content(block_messages(), {:compat, :openai})

      refute system.content =~ "cache_control"
      refute system.content =~ "ephemeral"
    end

    test "string-keyed messages are normalized too" do
      messages = [
        %{"role" => "system", "content" => [%{"type" => "text", "text" => "a"}]},
        %{"role" => "user", "content" => "hi"}
      ]

      [system | _] = Registry.normalize_message_content(messages, Providers.Ollama)
      assert system["content"] == "a"
    end

    test "all-string messages are returned as the SAME term (no needless rebuild)" do
      messages = flat_messages()

      assert Registry.normalize_message_content(messages, Providers.Ollama) === messages
    end

    test "extra message keys survive flattening" do
      messages = [
        %{
          role: "tool",
          tool_call_id: "call_1",
          name: "read_file",
          content: [%{type: "text", text: "file body"}]
        }
      ]

      [msg] = Registry.normalize_message_content(messages, {:compat, :openai})

      assert msg.content == "file body"
      assert msg.tool_call_id == "call_1"
      assert msg.name == "read_file"
    end
  end

  # ── Non-system messages share the defect ───────────────────────────────────

  describe "image blocks on user/tool turns" do
    # Exactly what MessageHandler.build_messages/3 emits for an attachment.
    defp image_messages do
      [
        %{
          role: "user",
          content: [
            %{type: "text", text: "what is in this screenshot?"},
            %{
              type: "image",
              source: %{type: "base64", media_type: "image/png", data: "aGVsbG8="}
            }
          ]
        }
      ]
    end

    test "an image-capable target keeps the blocks — its own encoder handles them" do
      # gpt-4o is catalogued with image input, and OpenAICompat encodes
      # `image_url` parts. Flattening here would make that encoder dead code.
      [user] =
        Registry.normalize_message_content(image_messages(), {:compat, :openai}, model: "gpt-4o")

      assert is_list(user.content), "the image must reach the provider's own encoder"
      assert Enum.any?(user.content, &match?(%{type: "image"}, &1))
    end

    test "an unknown model is passed through, not silently flattened" do
      [user] =
        Registry.normalize_message_content(image_messages(), {:compat, :openai},
          model: "some-model-nobody-catalogued"
        )

      assert is_list(user.content)
    end

    test "a fallback hop that dropped :model is passed through too" do
      [user] = Registry.normalize_message_content(image_messages(), {:compat, :openai})

      assert is_list(user.content)
    end

    test "a model the catalog knows to be text-only is flattened, and says why" do
      [user] =
        Registry.normalize_message_content(image_messages(), {:compat, :groq},
          model: "llama-3.1-8b-instant"
        )

      assert is_binary(user.content)
      assert user.content =~ "what is in this screenshot?"
      assert user.content =~ "does not accept image input"
      refute user.content =~ "aGVsbG8=", "the base64 payload must not be pasted into the prompt"
    end

    test "a transport with no image encoder is flattened, and says THAT instead" do
      # Ollama does not export `supports_image_content?/0`; it would raise on a
      # list. The placeholder must name the transport, not blame the model.
      [user] = Registry.normalize_message_content(image_messages(), Providers.Ollama)

      assert is_binary(user.content)
      assert user.content =~ "cannot send images"
      refute user.content =~ "does not accept image input"
    end

    test "a tool result carrying an image flattens instead of raising" do
      # ToolExecutor's {:image, media_type, b64, path} branch.
      messages = [
        %{
          role: "tool",
          tool_call_id: "call_2",
          name: "screenshot",
          content: [
            %{type: "text", text: "Image: /tmp/shot.png"},
            %{type: "image", source: %{type: "base64", media_type: "image/png", data: "eHl6"}}
          ]
        }
      ]

      [tool] = Registry.normalize_message_content(messages, Providers.Ollama)

      assert tool.content =~ "Image: /tmp/shot.png"
      assert tool.content =~ "cannot send images"
    end

    test "the old formatters really did raise on this shape (regression witness)" do
      blocks = [%{type: "text", text: "a"}, %{type: "text", text: "b"}]

      assert_raise ArgumentError, fn -> to_string(blocks) end
    end
  end

  # ── The wire body, per provider ────────────────────────────────────────────

  describe "wire body is byte-identical to the pre-cache-fix flat string" do
    setup do
      {server, port} = start_stub(@port_base, self(), 0)
      on_exit(fn -> Process.exit(server, :normal) end)
      {:ok, port: port}
    end

    # {provider_atom, url_env_key, url_suffix, other_env}
    @providers_under_test [
      {:openai, :openai_url, "/v1", [openai_api_key: "sk-test"]},
      {:groq, :groq_url, "/v1", [groq_api_key: "gsk-test"]},
      {:ollama, :ollama_url, "", []},
      {:cohere, :cohere_url, "", [cohere_api_key: "co-test"]},
      {:google, :google_url, "", [google_api_key: "goog-test"]}
    ]

    for {provider, url_key, suffix, other} <- @providers_under_test do
      test "#{provider}: block-shaped system produces the same body as the flat string",
           %{port: port} do
        provider = unquote(provider)
        url_key = unquote(url_key)
        suffix = unquote(suffix)
        other = unquote(other)

        with_env([{url_key, "http://127.0.0.1:#{port}#{suffix}"} | other], fn ->
          block_body = capture_chat_body(provider, block_messages())
          flat_body = capture_chat_body(provider, flat_messages())

          assert block_body != nil,
                 "#{provider} never reached the wire — it raised before sending " <>
                   "(this is the ArgumentError this fix exists to remove)"

          assert block_body == flat_body,
                 "#{provider} received a DIFFERENT request body for the block-shaped " <>
                   "system prompt than for the equivalent flat string"

          refute block_body =~ "cache_control",
                 "#{provider} must never see an Anthropic-only cache_control marker"

          assert block_body =~ @static_base
          assert block_body =~ @volatile
        end)
      end
    end
  end

  # ── The failure scenario, end to end ───────────────────────────────────────

  describe "Anthropic 5xx falls back to a working provider" do
    setup do
      test_pid = self()
      {anthropic_srv, anthropic_port} = start_stub(@port_base + 40, test_pid, 0, status: 503)
      {openai_srv, openai_port} = start_stub(@port_base + 60, test_pid, 0)

      prev =
        snapshot([
          :anthropic_url,
          :anthropic_api_key,
          :openai_url,
          :openai_api_key,
          :fallback_chain,
          :default_provider
        ])

      prev_retries = System.get_env("OSA_API_MAX_RETRIES")

      # One attempt per provider: this test is about the fallback HOP, not about
      # the backoff schedule, and the default schedule would take minutes.
      System.put_env("OSA_API_MAX_RETRIES", "0")

      put(:anthropic_url, "http://127.0.0.1:#{anthropic_port}/v1")
      put(:anthropic_api_key, "sk-ant-test-not-a-real-key")
      put(:openai_url, "http://127.0.0.1:#{openai_port}/v1")
      put(:openai_api_key, "sk-test-not-a-real-key")
      put(:fallback_chain, [:anthropic, :openai])
      put(:default_provider, :anthropic)

      on_exit(fn ->
        restore_all(prev)

        if prev_retries,
          do: System.put_env("OSA_API_MAX_RETRIES", prev_retries),
          else: System.delete_env("OSA_API_MAX_RETRIES")

        Process.exit(anthropic_srv, :normal)
        Process.exit(openai_srv, :normal)
      end)

      :ok
    end

    test "the fallback provider receives a VALID request and the call succeeds" do
      %{messages: messages} = anthropic_shaped_context()

      assert {:ok, result, provider} =
               FallbackChain.chat_with_fallback(messages, provider: :anthropic)

      assert provider in [:anthropic, :openai]
      assert result.content =~ "fallback answer"

      # And the request OpenAI actually received was well-formed: a string
      # system prompt carrying every block's text, with no Anthropic leftovers.
      bodies = drain_bodies()

      openai_body =
        Enum.find(bodies, fn {path, _raw} -> path =~ "chat/completions" end)

      assert {_path, raw} = openai_body, "the fallback provider was never called at all"

      decoded = Jason.decode!(raw)
      system = decoded["messages"] |> List.first()

      assert system["role"] == "system"

      assert is_binary(system["content"]),
             "the fallback provider was handed list content — it would raise ArgumentError"

      assert system["content"] == flat_system()
      refute raw =~ "cache_control"
    end

    test "without a working fallback the error is still surfaced honestly" do
      # Sanity companion: when the ONLY provider fails, we must still get the
      # all-providers-failed error rather than a false success.
      put(:fallback_chain, [:anthropic])

      %{messages: messages} = anthropic_shaped_context()

      assert {:error, reason} = FallbackChain.chat_with_fallback(messages, provider: :anthropic)
      assert is_binary(reason)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp anthropic_shaped_context, do: %{messages: block_messages()}

  defp put(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp snapshot(keys),
    do: Map.new(keys, fn k -> {k, Application.fetch_env(:optimal_system_agent, k)} end)

  defp restore_all(prev) do
    Enum.each(prev, fn
      {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
      {k, :error} -> Application.delete_env(:optimal_system_agent, k)
    end)
  end

  defp with_env(env, fun) do
    prev = snapshot(Keyword.keys(env))
    Enum.each(env, fn {k, v} -> put(k, v) end)

    try do
      fun.()
    after
      restore_all(prev)
    end
  end

  # Runs one chat/2 and returns the RAW request body the stub saw, or nil if the
  # provider raised before sending anything.
  defp capture_chat_body(provider, messages) do
    drain_bodies()
    Registry.chat(messages, provider: provider, max_tokens: 16)

    bodies = drain_bodies()

    # Ollama probes /api/tags and /api/show; only the request carrying the
    # conversation is the one under test.
    case Enum.find(bodies, fn {_path, raw} -> raw =~ @static_base end) do
      {_path, raw} -> raw
      nil -> nil
    end
  end

  defp drain_bodies(acc \\ []) do
    receive do
      {:captured_body, path, raw} -> drain_bodies([{path, raw} | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp start_stub(base, test_pid, attempt), do: start_stub(base, test_pid, attempt, [])

  defp start_stub(_base, _pid, attempt, _opts) when attempt > 20,
    do: flunk("could not bind a stub HTTP port after 20 attempts")

  defp start_stub(base, test_pid, attempt, opts) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.CapturePlug, {test_pid, Keyword.get(opts, :status, 200)}},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, test_pid, attempt + 1, opts)
    end
  end

  defmodule CapturePlug do
    @moduledoc false
    import Plug.Conn

    def init(state), do: state

    def call(conn, {test_pid, status}) do
      {:ok, raw, conn} = read_body(conn)
      send(test_pid, {:captured_body, conn.request_path, raw})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body_for(status))
    end

    # One payload that every provider's response parser can find *something* in.
    # The OpenAI shape is the one the fallback test asserts on; the rest only
    # need the request to have been sent.
    defp body_for(200) do
      Jason.encode!(%{
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "fallback answer"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1},
        "content" => [%{"type" => "text", "text" => "fallback answer"}],
        "message" => %{"role" => "assistant", "content" => "fallback answer"},
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "fallback answer"}], "role" => "model"}}
        ],
        "models" => []
      })
    end

    defp body_for(_status),
      do:
        Jason.encode!(%{
          "type" => "error",
          "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
        })
  end
end
