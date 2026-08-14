defmodule OptimalSystemAgent.Providers.MultimodalRequestAssemblyTest do
  @moduledoc """
  An attached image must survive the trip to a vision-capable provider, and must
  never be dropped in silence.

  `MessageHandler.build_messages/3` emits Anthropic's block shape
  (`%{type: "image", source: %{type: "base64", media_type: .., data: ..}}`) for
  EVERY provider. Before this change only `Anthropic` could read it:

    * `OpenAICompat.format_messages/1`'s generic clause did
      `%{"content" => to_string(content)}` — `to_string/1` on a list of maps
      raises `Protocol.UndefinedError`, killing the turn.
    * `Google`'s fallback `content_part/2` did the same on `msg["content"]`.
    * `Bedrock`'s `flatten_text/1` matched only text shapes and ended `_ -> ""`,
      so the image was SILENTLY DROPPED and the model answered confidently about
      an image it never received.

  Each provider now encodes its own native image part, and the image byte-budget
  (previously wired in at `Anthropic` only) understands all four wire shapes.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias OptimalSystemAgent.Providers.Bedrock
  alias OptimalSystemAgent.Providers.Google
  alias OptimalSystemAgent.Providers.ImageBudget
  alias OptimalSystemAgent.Providers.OpenAICompat

  @data "aGVsbG8td29ybGQtaW1hZ2UtYnl0ZXM="

  defp image_block(media_type \\ "image/png") do
    %{type: "image", source: %{type: "base64", media_type: media_type, data: @data}}
  end

  defp user_turn(text \\ "what is in this screenshot?") do
    %{role: "user", content: [%{type: "text", text: text}, image_block()]}
  end

  # ── OpenAI-compatible ─────────────────────────────────────────────────────

  describe "OpenAICompat.format_messages/1" do
    test "a block-list user turn no longer raises" do
      assert [%{"content" => content}] = OpenAICompat.format_messages([user_turn()])
      assert is_list(content)
    end

    test "the image becomes an image_url content part carrying a data URL" do
      [%{"content" => content}] = OpenAICompat.format_messages([user_turn()])

      assert %{"type" => "text", "text" => "what is in this screenshot?"} = Enum.at(content, 0)

      assert %{"type" => "image_url", "image_url" => %{"url" => url}} = Enum.at(content, 1)
      assert url == "data:image/png;base64,#{@data}"
    end

    test "the media type is carried through, not hardcoded" do
      msg = %{role: "user", content: [image_block("image/jpeg")]}
      [%{"content" => [part]}] = OpenAICompat.format_messages([msg])

      assert part["image_url"]["url"] =~ "data:image/jpeg;base64,"
    end

    test "a text-only turn is still a plain string (no wire change)" do
      msgs = [%{role: "user", content: "hello"}]
      assert [%{"content" => "hello"}] = OpenAICompat.format_messages(msgs)

      blocks = [%{role: "user", content: [%{type: "text", text: "hello"}]}]
      assert [%{"content" => "hello"}] = OpenAICompat.format_messages(blocks)
    end

    test "a tool turn cannot carry an image part, so it says the image was not sent" do
      msg = %{
        role: "tool",
        tool_call_id: "call_1",
        name: "screenshot",
        content: [%{type: "text", text: "Image: /tmp/shot.png"}, image_block()]
      }

      [%{"content" => content}] = OpenAICompat.format_messages([msg])

      assert is_binary(content), "the OpenAI `tool` role accepts only a string"
      assert content =~ "Image: /tmp/shot.png"
      assert content =~ "not sent"
      refute content =~ @data
    end
  end

  # ── Gemini ────────────────────────────────────────────────────────────────

  describe "Google.build_contents/1" do
    test "a block-list user turn no longer raises" do
      assert {_system, [%{"parts" => parts}]} = Google.build_contents([user_turn()])
      assert is_list(parts)
    end

    test "the image becomes an inlineData part" do
      {_system, [%{"parts" => parts}]} = Google.build_contents([user_turn()])

      assert %{"text" => "what is in this screenshot?"} = Enum.at(parts, 0)
      assert %{"inlineData" => %{"mimeType" => "image/png", "data" => @data}} = Enum.at(parts, 1)
    end

    test "a text-only turn is unchanged" do
      {_system, [%{"parts" => parts}]} =
        Google.build_contents([%{role: "user", content: "hello"}])

      assert parts == [%{"text" => "hello"}]
    end
  end

  # ── Bedrock Converse ──────────────────────────────────────────────────────

  describe "Bedrock.build_request_body/3" do
    test "the image is carried as a Converse image block, not dropped" do
      body =
        Bedrock.build_request_body([user_turn()], "anthropic.claude-3-5-sonnet-20241022-v2:0")

      [%{"content" => blocks}] = body["messages"]

      assert %{"text" => "what is in this screenshot?"} = Enum.at(blocks, 0)

      assert %{"image" => %{"format" => "png", "source" => %{"bytes" => @data}}} =
               Enum.at(blocks, 1)
    end

    test "an unsupported media type is reported, never silently dropped" do
      msg = %{role: "user", content: [image_block("image/tiff")]}
      body = Bedrock.build_request_body([msg], "anthropic.claude-3-5-sonnet-20241022-v2:0")

      [%{"content" => blocks}] = body["messages"]
      assert [%{"text" => text}] = blocks
      assert text =~ "could not be sent"
    end

    test "a text-only turn produces exactly one text block (no wire change)" do
      body =
        Bedrock.build_request_body(
          [%{role: "user", content: "hello"}],
          "anthropic.claude-3-5-sonnet-20241022-v2:0"
        )

      assert [%{"content" => [%{"text" => "hello"}]}] = body["messages"]
    end
  end

  # ── Budget: every provider, not just Anthropic ────────────────────────────

  describe "ImageBudget across wire shapes" do
    # 3 MB of base64 per image, well over the 1 MB cap used below.
    defp big, do: String.duplicate("A", 3 * 1024 * 1024)

    test "OpenAI image_url parts are counted and evicted" do
      body = %{
        model: "gpt-4o",
        messages: [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:image/png;base64," <> big()}
              },
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:image/png;base64," <> big()}
              }
            ]
          }
        ]
      }

      assert ImageBudget.body_byte_size(body) > 6 * 1024 * 1024

      {new_body, outcome} =
        ImageBudget.run(body, cap_bytes: 1_000_000, headroom_bytes: 0, reclaim_bytes: 0)

      assert outcome.evicted > 0
      [%{"content" => content}] = new_body.messages
      assert Enum.any?(content, &(&1["text"] == ImageBudget.placeholder()))
    end

    test "Bedrock image blocks are counted and evicted with a bare text block" do
      body = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"image" => %{"format" => "png", "source" => %{"bytes" => big()}}},
              %{"image" => %{"format" => "png", "source" => %{"bytes" => big()}}}
            ]
          }
        ]
      }

      {new_body, outcome} =
        ImageBudget.run(body, cap_bytes: 1_000_000, headroom_bytes: 0, reclaim_bytes: 0)

      assert outcome.evicted > 0
      [%{"content" => content}] = new_body["messages"]

      assert Enum.any?(content, &(&1 == %{"text" => ImageBudget.placeholder()})),
             "Converse has no `type` field on a text block"
    end

    test "Gemini contents/parts are seen at all (they used to be invisible)" do
      body = %{
        contents: [
          %{
            "role" => "user",
            "parts" => [
              %{"inlineData" => %{"mimeType" => "image/png", "data" => big()}},
              %{"inlineData" => %{"mimeType" => "image/png", "data" => big()}}
            ]
          }
        ]
      }

      assert ImageBudget.body_byte_size(body) > 6 * 1024 * 1024

      {new_body, outcome} =
        ImageBudget.run(body, cap_bytes: 1_000_000, headroom_bytes: 0, reclaim_bytes: 0)

      assert outcome.evicted > 0
      [%{"parts" => parts}] = new_body.contents
      assert Enum.any?(parts, &(&1 == %{"text" => ImageBudget.placeholder()}))
    end

    test "the eviction placeholder still tells the model not to reason from memory" do
      assert ImageBudget.placeholder() =~ "Do not describe or reason about its contents"
    end
  end

  # ── Capability gate ───────────────────────────────────────────────────────

  describe "ImageBudget.gate_unsupported/3" do
    test "a model the catalog knows to be text-only gets an explicit note, not a drop" do
      refute ImageBudget.vision_capable?(:groq, "llama-3.1-8b-instant"),
             "catalog fixture assumption: this model has text-only input modalities"

      body = %{
        model: "llama-3.1-8b-instant",
        messages: [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "hi"},
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:image/png;base64,#{@data}"}
              }
            ]
          }
        ]
      }

      gated = ImageBudget.gate_unsupported(body, :groq, "llama-3.1-8b-instant")
      [%{"content" => content}] = gated.messages

      refute Enum.any?(content, &Map.has_key?(&1, "image_url"))

      assert Enum.any?(
               content,
               &(is_binary(&1["text"]) and &1["text"] =~ "does not accept image")
             )
    end

    test "an unknown model is left alone — the provider's own error is more truthful" do
      assert ImageBudget.vision_capable?(:openai, "some-local-model-nobody-catalogued")

      body = %{model: "x", messages: [%{"role" => "user", "content" => [image_block()]}]}

      assert ImageBudget.gate_unsupported(body, :openai, "some-local-model-nobody-catalogued") ==
               body
    end
  end

  # ── End to end, at the dispatch boundary ──────────────────────────────────
  #
  # The encoder tests above prove each provider module CAN encode an image. This
  # section proves the image actually gets there: in at `Registry.chat/2` with
  # the block shape `MessageHandler.build_messages/3` emits, out on the wire of a
  # stub HTTP server. `Registry.normalize_message_content/3` sat between the two
  # and flattened every image block to a text placeholder, which made all of the
  # encoders unreachable.
  describe "Registry.chat/2 to the wire" do
    @port_base 11_701

    setup do
      {server, port} = start_stub(@port_base, self())
      on_exit(fn -> Process.exit(server, :normal) end)
      {:ok, port: port}
    end

    test "an OpenAI vision model receives the image as an image_url data URL", %{port: port} do
      with_env([openai_url: "http://127.0.0.1:#{port}/v1", openai_api_key: "sk-test"], fn ->
        raw = capture_body(:openai, [user_turn()], model: "gpt-4o")

        assert raw, "the request never reached the wire"
        decoded = Jason.decode!(raw)
        [user] = decoded["messages"]

        assert is_list(user["content"]),
               "the image was flattened away before the provider could encode it"

        assert %{"type" => "image_url", "image_url" => %{"url" => url}} =
                 Enum.find(user["content"], &(&1["type"] == "image_url"))

        assert url == "data:image/png;base64,#{@data}"
        assert Enum.any?(user["content"], &(&1["text"] == "what is in this screenshot?"))
      end)
    end

    test "a Gemini vision model receives the image as an inlineData part", %{port: port} do
      with_env([google_url: "http://127.0.0.1:#{port}", google_api_key: "goog-test"], fn ->
        raw = capture_body(:google, [user_turn()], model: "gemini-2.5-pro")

        assert raw, "the request never reached the wire"
        decoded = Jason.decode!(raw)
        [content] = decoded["contents"]

        assert %{"inlineData" => %{"mimeType" => "image/png", "data" => @data}} =
                 Enum.find(content["parts"], &Map.has_key?(&1, "inlineData"))
      end)
    end

    test "Ollama receives the image in its native sibling field", %{port: port} do
      # This case used to assert the opposite — that Ollama never saw the bytes
      # and got the "cannot send images" placeholder instead. That was true, and
      # it was the defect: Ollama's `/api/chat` carries images as an `"images"`
      # sibling of `"content"`, and OSA had simply never learned the shape.
      with_env([ollama_url: "http://127.0.0.1:#{port}"], fn ->
        raw = capture_body(:ollama, [user_turn()], model: "llava:7b")

        assert raw, "the request never reached the wire"
        refute raw =~ "cannot send images"

        [user] = Jason.decode!(raw)["messages"]
        assert user["images"] == [@data]
        assert user["content"] =~ "what is in this screenshot?"
      end)
    end

    test "a transport with no image encoder never sees the bytes, and is told why", %{port: port} do
      with_env([cohere_url: "http://127.0.0.1:#{port}", cohere_api_key: "co-test"], fn ->
        raw = capture_body(:cohere, [user_turn()], model: "command-r-plus")

        assert raw, "the request never reached the wire"
        refute raw =~ @data, "an image-incapable transport must not receive image bytes"
        assert raw =~ "cannot send images"
      end)
    end

    test "a turn with NO image is byte-identical to before the carve-out", %{port: port} do
      with_env([openai_url: "http://127.0.0.1:#{port}/v1", openai_api_key: "sk-test"], fn ->
        # The block-shaped system prompt Context.build_system_message/4 emits for
        # Anthropic, plus a plain user turn. Both must still flatten.
        blocks = [
          %{
            role: "system",
            content: [
              %{type: "text", text: "STATIC", cache_control: %{type: "ephemeral"}},
              %{type: "text", text: "VOLATILE"}
            ]
          },
          %{role: "user", content: "hi there"}
        ]

        flat = [
          %{role: "system", content: "STATIC\n\nVOLATILE"},
          %{role: "user", content: "hi there"}
        ]

        block_body = capture_body(:openai, blocks, model: "gpt-4o")
        flat_body = capture_body(:openai, flat, model: "gpt-4o")

        assert block_body != nil

        assert block_body == flat_body,
               "the image carve-out must not touch text-only structured content"

        refute block_body =~ "cache_control"
      end)
    end
  end

  # ── Harness ───────────────────────────────────────────────────────────────

  defp capture_body(provider, messages, opts) do
    drain()
    OptimalSystemAgent.Providers.Registry.chat(messages, [provider: provider] ++ opts)

    drain()
    |> Enum.map(&elem(&1, 1))
    |> Enum.find(&(&1 =~ "screenshot" or &1 =~ "hi there"))
  end

  defp drain(acc \\ []) do
    receive do
      {:captured_body, path, raw} -> drain([{path, raw} | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp with_env(env, fun) do
    prev = Map.new(env, fn {k, _} -> {k, Application.fetch_env(:optimal_system_agent, k)} end)
    Enum.each(env, fn {k, v} -> Application.put_env(:optimal_system_agent, k, v) end)

    try do
      fun.()
    after
      Enum.each(prev, fn
        {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
        {k, :error} -> Application.delete_env(:optimal_system_agent, k)
      end)
    end
  end

  defp start_stub(base, test_pid, attempt \\ 0)

  defp start_stub(_base, _pid, attempt) when attempt > 20,
    do: flunk("could not bind a stub HTTP port after 20 attempts")

  defp start_stub(base, test_pid, attempt) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.CapturePlug, test_pid},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, test_pid, attempt + 1)
    end
  end

  defmodule CapturePlug do
    @moduledoc false
    import Plug.Conn

    def init(state), do: state

    def call(conn, test_pid) do
      {:ok, raw, conn} = read_body(conn)
      send(test_pid, {:captured_body, conn.request_path, raw})

      body =
        Jason.encode!(%{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
          ],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1},
          "message" => %{"role" => "assistant", "content" => "ok"},
          "candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}], "role" => "model"}}],
          "models" => []
        })

      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end
end
