defmodule OptimalSystemAgent.Providers.OpenAICompatSSERecoveryTest do
  @moduledoc """
  A gateway that only speaks SSE must not turn a successful call into gibberish.

  `do_chat/5`'s success clause matches `%{status: 200, body: %{"choices" => …}}`.
  An endpoint that answers a NON-streaming request with an event stream anyway
  — common for thin OpenAI-compatible proxies and local servers — decodes to a
  binary, misses that clause, and falls through to the generic non-200 arm,
  where `extract_error_message/1` renders `inspect(body)`. The user is shown a
  wall of escaped `data: {...}` frames labelled as the error, for a request that
  actually succeeded, and no recovery is attempted.

  OSA already has the inverse (`Registry.stream_with_fallback/5` drops a failing
  stream to sync). This pins the missing direction.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.OpenAICompat

  @port_base 23_100

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    window = @port_base + rem(System.unique_integer([:positive]), 200) * 2
    {srv, port} = start_stub(window, agent, 0)
    on_exit(fn -> Process.exit(srv, :kill) end)
    {:ok, agent: agent, base: "http://127.0.0.1:#{port}/v1"}
  end

  defp modes(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  test "a non-streaming call answered with SSE yields the assembled answer", %{
    agent: a,
    base: base
  } do
    assert {:ok, result} =
             OpenAICompat.chat(base, "sk-test-not-a-real-key", "m", msgs(), [])

    assert result.content == "Hello, world!",
           "the recovery must return the model's actual answer, not a rendering of " <>
             "the transport: #{inspect(result)}"

    assert :stream in modes(a),
           "the recovery must actually re-issue the request as a stream: #{inspect(modes(a))}"
  end

  test "the user is never shown raw SSE frames as an error message", %{base: base} do
    result = OpenAICompat.chat(base, "sk-test-not-a-real-key", "m", msgs(), [])

    case result do
      {:ok, _} ->
        :ok

      {:error, message} ->
        refute message =~ "data:",
               "raw SSE frames must never be presented as the error text: " <> message
    end
  end

  defp msgs, do: [%{role: "user", content: "hello"}]

  # ── Helpers ────────────────────────────────────────────────────────────────

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

    # SSE for BOTH request shapes — the whole point is a gateway with no
    # non-streaming mode at all.
    def call(conn, agent) do
      {:ok, raw, conn} = read_body(conn)
      streaming? = String.contains?(raw, "\"stream\":true")
      Agent.update(agent, &[if(streaming?, do: :stream, else: :sync) | &1])

      body =
        chunk_frame(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "Hello, "}}]}) <>
          chunk_frame(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "world!"}}]}) <>
          chunk_frame(%{
            "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
          }) <>
          "data: [DONE]\n\n"

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      {:ok, conn} = chunk(conn, body)
      conn
    end

    def init(agent), do: agent

    defp chunk_frame(map), do: "data: #{Jason.encode!(map)}\n\n"
  end
end
