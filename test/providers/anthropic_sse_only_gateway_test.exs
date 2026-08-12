defmodule OptimalSystemAgent.Providers.AnthropicSseOnlyGatewayTest do
  @moduledoc """
  An Anthropic-compatible gateway that only speaks SSE answers a NON-streaming
  `/messages` request with an event stream anyway. `Anthropic.chat/2` must
  still return the real answer.

  Before the fix, the `{:ok, %{status: 200, body: resp}}` arm carried no guard,
  so the SSE binary matched it and was treated as a decoded response:
  `extract_content/1` and `extract_tool_calls/1` both fall through to their
  catch-all clauses on a binary, so the caller got
  `{:ok, %{content: "", tool_calls: []}}` — a silent, empty, SUCCESSFUL answer,
  with the real reply sitting unparsed in `body`. `OpenAICompat` already had
  the sync→stream recovery; this is the same recovery with Anthropic's
  collector.

  Everything here runs against a local Bandit stub on 127.0.0.1. No request
  leaves the machine and no real provider is contacted.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Anthropic

  @port_base 19_460

  # The gateway's reply, as Anthropic SSE. Sent verbatim for BOTH the
  # non-streaming request (the bug) and the re-issued streaming one (the fix).
  @sse [
         ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":11,"output_tokens":0}}}\n\n),
         ~s(event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n),
         ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"recovered "}}\n\n),
         ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"answer"}}\n\n),
         ~s(event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n),
         ~s(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}\n\n),
         ~s(event: message_stop\ndata: {"type":"message_stop"}\n\n)
       ]
       |> Enum.join()

  setup do
    Code.ensure_loaded!(Anthropic)

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    window = @port_base + rem(System.unique_integer([:positive]), 100) * 2
    {srv, port} = start_stub(window, counter, 0)

    prev = snapshot([:anthropic_url, :anthropic_api_key, :anthropic_model])

    Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:#{port}/v1")
    Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test-not-a-real-key")

    on_exit(fn ->
      restore_all(prev)
      Process.exit(srv, :kill)
    end)

    {:ok, counter: counter}
  end

  describe "sse_body?/1" do
    test "recognizes both Anthropic SSE prefixes" do
      assert Anthropic.sse_body?("event: message_start\ndata: {}\n\n")
      assert Anthropic.sse_body?("data: {\"type\":\"message_stop\"}\n\n")
      assert Anthropic.sse_body?("  \n data: {}")
    end

    test "does not mistake JSON or prose for a stream" do
      refute Anthropic.sse_body?(~s({"content":[{"type":"text","text":"hi"}]}))
      refute Anthropic.sse_body?("Bad Gateway")
      refute Anthropic.sse_body?(%{"content" => []})
      refute Anthropic.sse_body?(nil)
    end
  end

  describe "chat/2 against an SSE-only gateway" do
    test "returns the real answer instead of a silent empty success", %{counter: counter} do
      assert {:ok, result} = Anthropic.chat([%{role: "user", content: "hi"}], model: "claude-x")

      assert result.content == "recovered answer",
             "the SSE body was not collected — got #{inspect(result.content)}"

      refute result.content == "",
             "an SSE-only gateway still surfaces as an empty successful answer"

      assert result.stop_reason == "end_turn"

      # Exactly one recovery: the original sync request, then the re-issued
      # stream. Anything more means the stream fell back into sync and looped.
      assert Agent.get(counter, & &1) == 2
    end

    test "the recovery does not recurse when the re-issued stream also fails" do
      # Point at a closed port: the sync request fails outright, so the SSE
      # recovery never starts, and the failure is reported once.
      Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:1/v1")

      assert {:error, msg} = Anthropic.chat([%{role: "user", content: "hi"}], model: "claude-x")
      assert is_binary(msg)
    end
  end

  # ── stub ────────────────────────────────────────────────────────────────

  defp snapshot(keys),
    do: Map.new(keys, fn k -> {k, Application.fetch_env(:optimal_system_agent, k)} end)

  defp restore_all(prev) do
    Enum.each(prev, fn
      {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
      {k, :error} -> Application.delete_env(:optimal_system_agent, k)
    end)
  end

  defp start_stub(_base, _counter, attempt) when attempt > 20,
    do: flunk("could not bind a stub HTTP port after 20 attempts")

  defp start_stub(base, counter, attempt) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.SsePlug, %{counter: counter, sse: @sse}},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, counter, attempt + 1)
    end
  end

  defmodule SsePlug do
    @moduledoc """
    A gateway that ONLY speaks SSE: it answers with an event stream whether or
    not the request asked to stream. That is the whole defect being reproduced.
    """
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{counter: counter, sse: sse}) do
      {:ok, _raw, conn} = read_body(conn)
      Agent.update(counter, &(&1 + 1))

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, sse)
    end
  end
end
