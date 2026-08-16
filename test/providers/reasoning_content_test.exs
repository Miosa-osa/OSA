defmodule OptimalSystemAgent.Providers.ReasoningContentTest do
  @moduledoc """
  Two-thirds of the billed output on the OpenRouter route was discarded.

  `openai_compat.ex` matched `"reasoning_content"` — DeepSeek's spelling — on
  the streaming path only. OpenRouter's unified interface returns the same
  field as a bare `"reasoning"`, and nothing in `lib/providers/` matched it, so
  the model's entire deliberation was parsed, bound to nothing, and dropped.
  The tokens were still billed as output, so every OpenRouter transcript on
  disk is missing most of what the run paid for, and the in:out ratio computed
  from those transcripts is ~3x too high on the output side.

  These tests pin BOTH spellings on BOTH paths, plus the payload that carries
  neither (which must not gain a `:reasoning` key), plus the three contracts
  that make the fix safe: reasoning never joins `:content`, never reaches the
  wire on the next turn, and never touches `usage`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.OpenAICompat
  alias OptimalSystemAgent.Providers.ReasoningContent

  @port_base 23_600

  # ── The normaliser ────────────────────────────────────────────────────────

  describe "extract/1 — every spelling an OpenAI-shaped backend uses" do
    test "DeepSeek's `reasoning_content`" do
      assert ReasoningContent.extract(%{"reasoning_content" => "weighing it up"}) ==
               "weighing it up"
    end

    test "OpenRouter's unified `reasoning` — the spelling nothing matched" do
      assert ReasoningContent.extract(%{"reasoning" => "weighing it up"}) == "weighing it up"
    end

    test "structured `reasoning_details` blocks" do
      payload = %{
        "reasoning_details" => [
          %{"type" => "reasoning.text", "text" => "first "},
          %{"type" => "reasoning.text", "text" => "second"}
        ]
      }

      assert ReasoningContent.extract(payload) == "first second"
    end

    test "a summary block is text too" do
      payload = %{"reasoning_details" => [%{"type" => "reasoning.summary", "summary" => "gist"}]}
      assert ReasoningContent.extract(payload) == "gist"
    end

    test "an encrypted block has no text and must not surface its blob" do
      payload = %{
        "reasoning_details" => [%{"type" => "reasoning.encrypted", "data" => "b2JmdXNjYXRlZA=="}]
      }

      assert ReasoningContent.extract(payload) == ""
    end

    test "both spellings in one payload are the SAME text, not two" do
      # OpenRouter passes a DeepSeek upstream's `reasoning_content` through
      # while also populating its own `reasoning`. Concatenating would print
      # the model's deliberation twice.
      payload = %{"reasoning_content" => "once", "reasoning" => "once"}
      assert ReasoningContent.extract(payload) == "once"
    end

    test "a payload with neither key yields nothing" do
      assert ReasoningContent.extract(%{"content" => "hello"}) == ""
      assert ReasoningContent.extract(%{}) == ""
    end

    test "never raises on a shape no vendor documents" do
      assert ReasoningContent.extract(%{"reasoning" => 42}) == ""
      assert ReasoningContent.extract(%{"reasoning" => nil}) == ""
      assert ReasoningContent.extract(%{"reasoning" => ""}) == ""
      assert ReasoningContent.extract("not a map") == ""
      assert ReasoningContent.extract(nil) == ""
    end
  end

  # ── Streaming path — the one the agent loop takes ─────────────────────────

  describe "streaming" do
    test "`reasoning_content` deltas surface as reasoning and land on the result" do
      result = stream(["Thinking ", "hard"], "reasoning_content")

      assert result.reasoning == "Thinking hard"
      assert_received {:sse_test_callback, {:thinking_delta, "Thinking "}}
      assert_received {:sse_test_callback, {:thinking_delta, "hard"}}
    end

    test "`reasoning` deltas do too — this is the bug" do
      result = stream(["Thinking ", "hard"], "reasoning")

      assert result.reasoning == "Thinking hard",
             "OpenRouter's unified `reasoning` key was being dropped on the floor " <>
               "while its tokens were billed as output"

      assert_received {:sse_test_callback, {:thinking_delta, "Thinking "}}
      assert_received {:sse_test_callback, {:thinking_delta, "hard"}}
    end

    test "reasoning is NOT the answer — it never joins :content" do
      result =
        OpenAICompat.stream_from_sse_chunks([
          frame(%{"reasoning" => "deliberating"}),
          frame(%{"content" => "42"}),
          done_frame()
        ])

      assert result.content == "42"
      assert result.reasoning == "deliberating"
    end

    test "a stream with no reasoning gains no :reasoning key" do
      result =
        OpenAICompat.stream_from_sse_chunks([frame(%{"content" => "42"}), done_frame()])

      refute Map.has_key?(result, :reasoning),
             "absence must stay absence: #{inspect(result)}"

      assert result.content == "42"
      refute_received {:sse_test_callback, {:thinking_delta, _}}
    end

    test "usage is untouched — reasoning tokens are already inside completion_tokens" do
      result =
        OpenAICompat.stream_from_sse_chunks([
          frame(%{"reasoning" => "a long deliberation that bills as output"}),
          frame(%{"content" => "ok"}),
          done_frame()
        ])

      # 160 is what the provider billed; the reasoning text must not be added
      # to it a second time. This is the `reconcile_prompt_slices/2` shape.
      assert result.usage.output_tokens == 160
      assert result.usage.input_tokens == 100
    end
  end

  # ── Non-streaming path — had no reasoning handling at all ─────────────────

  describe "non-streaming" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      window = @port_base + rem(System.unique_integer([:positive]), 200) * 2
      {srv, port} = start_stub(window, agent, 0)
      on_exit(fn -> Process.exit(srv, :kill) end)
      {:ok, agent: agent, base: "http://127.0.0.1:#{port}/v1"}
    end

    test "`reasoning` on the sync message reaches the caller", %{agent: a, base: base} do
      Agent.update(a, fn _ -> %{"reasoning" => "sync deliberation"} end)

      assert {:ok, result} = OpenAICompat.chat(base, "sk-not-real", "m", msgs(), [])
      assert result.reasoning == "sync deliberation"
      assert result.content == "the answer"
    end

    test "`reasoning_content` on the sync message reaches the caller too", %{
      agent: a,
      base: base
    } do
      Agent.update(a, fn _ -> %{"reasoning_content" => "sync deliberation"} end)

      assert {:ok, result} = OpenAICompat.chat(base, "sk-not-real", "m", msgs(), [])
      assert result.reasoning == "sync deliberation"
    end

    test "a message with neither gains no :reasoning key", %{agent: a, base: base} do
      Agent.update(a, fn _ -> %{} end)

      assert {:ok, result} = OpenAICompat.chat(base, "sk-not-real", "m", msgs(), [])
      refute Map.has_key?(result, :reasoning)
      assert result.content == "the answer"
    end
  end

  # ── The wire contract ─────────────────────────────────────────────────────

  describe "reasoning must not be replayed to the provider" do
    test "format_messages/1 emits no reasoning field for an assistant turn carrying one" do
      # Unlike Anthropic, which REQUIRES signed thinking blocks to be echoed
      # back, chat/completions documents `reasoning` as response-only. Even if
      # something upstream put it on the message, it must not reach the wire.
      [wire] =
        OpenAICompat.format_messages([
          %{role: "assistant", content: "hi", reasoning: "secret deliberation"}
        ])

      refute Map.has_key?(wire, "reasoning")
      refute Map.has_key?(wire, "reasoning_content")
      refute wire["content"] =~ "secret"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp stream(texts, key) do
    chunks = Enum.map(texts, &frame(%{key => &1})) ++ [done_frame()]
    OpenAICompat.stream_from_sse_chunks(chunks)
  end

  defp frame(delta),
    do: "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => delta}]})}\n\n"

  defp done_frame do
    "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}], "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 160}})}\n\n" <>
      "data: [DONE]\n\n"
  end

  defp msgs, do: [%{role: "user", content: "hello"}]

  defp start_stub(_base, _agent, attempt) when attempt > 20,
    do: flunk("could not bind a stub HTTP port after 20 attempts")

  defp start_stub(base, agent, attempt) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.StubPlug, agent},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, agent, attempt + 1)
    end
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, _raw, conn} = read_body(conn)
      extra = Agent.get(agent, & &1) || %{}

      body = %{
        "choices" => [
          %{
            "index" => 0,
            "message" => Map.merge(%{"role" => "assistant", "content" => "the answer"}, extra),
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 160}
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end
end
