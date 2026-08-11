defmodule OptimalSystemAgent.Agent.ThinkingRedactionTest do
  @moduledoc """
  Reasoning text is user-visible provider output and gets redacted like the rest.

  Every other path that puts provider text on screen or on disk pipes it
  through `Trajectory.redact/1` first — `Channels.CLI.Events` does it for tool
  previews and errors ("redact before slicing so a truncated key never shows"),
  and `Trajectory.truncate/1` does it for every recorded assistant response.

  The two reasoning paths did not:

    * `Agent.Loop.LLMClient`'s `{:thinking_delta, text}` clause forwarded `text`
      verbatim into the `:thinking_delta` bus event AND the `{:osa_event, ...}`
      PubSub broadcast the TUI renders from, and
    * `Agent.Scratchpad.process_response/2` emitted the joined `<think>` blocks
      verbatim as both `:thinking_delta` and `:thinking_captured`.

  Reasoning routinely quotes back the contents of a file the model has just
  read, so this is the single most likely place for a `.env` dump or an
  `Authorization:` header to reach terminal scrollback and persisted session
  state.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Scratchpad
  alias OptimalSystemAgent.Events.Bus

  # A real-shaped OpenAI key. `Trajectory`'s `sk-` pattern needs 16+ chars.
  @secret "sk-abcdefghijklmnopqrstuvwxyz012345"
  @port_base 22_700

  describe "Scratchpad.process_response/2" do
    setup do
      subscribe_bus()
      :ok
    end

    test "redacts secrets quoted inside <think> blocks before emitting them" do
      session = "redaction-scratchpad-#{System.unique_integer([:positive])}"

      text =
        "<think>The .env I just read contains OPENAI_API_KEY=#{@secret} " <>
          "so I will reuse it.</think>visible answer"

      assert "visible answer" = Scratchpad.process_response(text, session) |> String.trim()

      thinking = collect_thinking(session)

      assert thinking != [], "precondition: a thinking event must have been emitted"

      for {event, body} <- thinking do
        refute body =~ @secret,
               "#{event} carried the raw key into the bus (and from there to the TUI and " <>
                 "the learning engine): #{body}"
      end
    end
  end

  describe "LLMClient.llm_chat_stream/3" do
    setup do
      Code.ensure_loaded!(OptimalSystemAgent.Providers.Anthropic)

      window = @port_base + rem(System.unique_integer([:positive]), 200) * 2
      {srv, port} = start_stub(window, 0)

      prev = snapshot([:anthropic_url, :anthropic_api_key, :default_provider])
      put(:anthropic_url, "http://127.0.0.1:#{port}/v1")
      put(:anthropic_api_key, "sk-ant-test-not-a-real-key")

      on_exit(fn ->
        restore_all(prev)
        Process.exit(srv, :kill)
      end)

      :ok
    end

    test "redacts a streamed :thinking_delta on both the bus and the PubSub topic" do
      session = "redaction-stream-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session}")
      subscribe_bus()

      state = %{session_id: session, provider: :anthropic, model: "stub"}
      LLMClient.llm_chat_stream(state, [%{role: "user", content: "hi"}], max_tokens: 64)

      pubsub = collect_pubsub_thinking()
      bus = collect_thinking(session)

      assert pubsub != [], "precondition: a thinking delta must have reached the PubSub topic"
      assert bus != [], "precondition: a thinking delta must have reached the bus"

      for body <- pubsub do
        refute body =~ @secret, "the TUI renders this text verbatim into scrollback: #{body}"
      end

      for {event, body} <- bus do
        refute body =~ @secret, "#{event} is persisted into session state: #{body}"
      end
    end
  end

  # ── Collectors ─────────────────────────────────────────────────────────────

  # `Bus` has no subscribe/1 — handlers are functions, and `emit/3` dispatches
  # them from a supervised task, so everything here is asynchronous.
  defp subscribe_bus do
    test_pid = self()

    # Handlers receive the whole CloudEvents-shaped Event map; the map passed to
    # `Bus.emit/2` lands under `:data`.
    ref =
      Bus.register_handler(:system_event, fn payload ->
        send(test_pid, {:bus, Map.get(payload, :data)})
      end)

    on_exit(fn -> Bus.unregister_handler(:system_event, ref) end)
    :ok
  end

  defp collect_thinking(session, acc \\ []) do
    receive do
      {:bus, %{event: event, session_id: ^session} = payload}
      when event in [:thinking_delta, :thinking_captured] ->
        body = Map.get(payload, :delta) || Map.get(payload, :text) || ""
        collect_thinking(session, [{event, body} | acc])

      {:bus, _} ->
        collect_thinking(session, acc)
    after
      800 -> Enum.reverse(acc)
    end
  end

  defp collect_pubsub_thinking(acc \\ []) do
    receive do
      {:osa_event, %{type: :thinking_delta, text: text}} ->
        collect_pubsub_thinking([text | acc])

      {:osa_event, _} ->
        collect_pubsub_thinking(acc)
    after
      800 -> Enum.reverse(acc)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp put(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp snapshot(keys),
    do: Map.new(keys, fn k -> {k, Application.fetch_env(:optimal_system_agent, k)} end)

  defp restore_all(prev) do
    Enum.each(prev, fn
      {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
      {k, :error} -> Application.delete_env(:optimal_system_agent, k)
    end)
  end

  defp start_stub(_base, attempt) when attempt > 20,
    do: flunk("could not bind a stub HTTP port after 20 attempts")

  defp start_stub(base, attempt) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.StubPlug, @secret},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, attempt + 1)
    end
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(secret), do: secret

    def call(conn, secret) do
      {:ok, _raw, conn} = read_body(conn)

      body =
        sse("message_start", message_start()) <>
          sse("content_block_start", thinking_block_start()) <>
          sse("content_block_delta", thinking_delta(secret)) <>
          sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}) <>
          sse("message_delta", message_delta()) <>
          sse("message_stop", %{"type" => "message_stop"})

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      {:ok, conn} = chunk(conn, body)
      conn
    end

    defp sse(event, data), do: "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

    defp message_start do
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_stub",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => "stub",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
        }
      }
    end

    defp thinking_block_start do
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      }
    end

    defp thinking_delta(secret) do
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{
          "type" => "thinking_delta",
          "thinking" =>
            "The .env file I just read has OPENAI_API_KEY=#{secret}; I can reuse that."
        }
      }
    end

    defp message_delta do
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 2}
      }
    end
  end
end
