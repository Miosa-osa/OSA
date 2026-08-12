defmodule OptimalSystemAgent.Providers.AnthropicCacheAttributionTest do
  @moduledoc """
  The attributor is actually WIRED INTO the Anthropic provider.

  `cache_attribution_test.exs` proves the verdicts are right. This proves they
  are reached: a correct attributor that no request path calls is a module, not
  a diagnostic. So these drive `Anthropic.chat/2` and `Anthropic.chat_stream/3`
  against a local stub that reports a cache hit and then a cache miss, and
  assert the break was recorded for the SESSION's scope.

  ## Not verified against a live provider

  The stub's `cache_read_input_tokens` are fixtures. No Anthropic endpoint is
  reachable from this machine, so no number in this file was ever produced by
  Anthropic's cache. What is proven is that whatever the provider reports flows
  into attribution on both the sync and streaming paths.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.{Anthropic, CacheAttribution}

  @model "claude-sonnet-4-6"

  setup do
    port = 11_700 + rem(System.unique_integer([:positive]), 200)
    # Two responses, in order: a healthy cache read, then a total miss.
    {:ok, reads} = Agent.start_link(fn -> [30_000, 0] end)
    srv = start_stub(port, reads)

    prev_url = Application.get_env(:optimal_system_agent, :anthropic_url)
    prev_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)

    Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:#{port}/v1")
    Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test-not-a-real-key")

    session = "attrib-#{System.unique_integer([:positive])}"
    CacheAttribution.reset(session)

    on_exit(fn ->
      Process.exit(srv, :kill)
      CacheAttribution.reset(session)
      restore(:anthropic_url, prev_url)
      restore(:anthropic_api_key, prev_key)
    end)

    {:ok, session: session}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp msgs, do: [%{role: "user", content: "hi"}]

  defp tools(schema),
    do: [
      %{name: "bash", description: "run", parameters: %{"type" => "object"}},
      %{name: "read", description: "read", parameters: schema}
    ]

  test "a sync request whose tool schema changed records a break naming that tool", %{
    session: session
  } do
    assert {:ok, _} =
             Anthropic.chat(msgs(),
               model: @model,
               session_id: session,
               tools: tools(%{"type" => "object"})
             )

    # Nothing to attribute yet — one request is not a comparison.
    assert CacheAttribution.last_break(session) == nil

    assert {:ok, _} =
             Anthropic.chat(msgs(),
               model: @model,
               session_id: session,
               tools: tools(%{"type" => "object", "properties" => %{"offset" => %{}}})
             )

    assert %{verdict: verdict, from: 30_000, to: 0} = CacheAttribution.last_break(session)
    assert verdict =~ "tool prompt/schema changed, same tool set: read"
  end

  test "the streaming path attributes too", %{session: session} do
    for _ <- 1..2 do
      Anthropic.chat_stream(msgs(), fn _ -> :ok end,
        model: @model,
        session_id: session,
        tools: tools(%{"type" => "object"})
      )
    end

    # Byte-identical prompts, so the only honest verdict is expiry / server-side.
    assert %{verdict: verdict} = CacheAttribution.last_break(session)
    assert verdict =~ "prompt unchanged"
  end

  test "a call with no session id does not pollute a live session's scope", %{session: session} do
    Anthropic.chat(msgs(), model: @model, session_id: session, tools: tools(%{"a" => 1}))
    # Compactor / verifier style call — no session id, so it lands in "default".
    Anthropic.chat(msgs(), model: @model, tools: tools(%{"b" => 2}))

    assert CacheAttribution.last_break(session) == nil
  end

  # ── stub ──────────────────────────────────────────────────────────────────

  defp start_stub(port, reads) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])

        send(parent, :ready)
        accept_loop(listen, reads)
      end)

    receive do
      :ready -> :ok
    after
      5_000 -> flunk("stub did not start")
    end

    pid
  end

  defp accept_loop(listen, reads) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handle(socket, reads)
        accept_loop(listen, reads)

      _ ->
        :ok
    end
  end

  defp handle(socket, reads) do
    req = read_all(socket, "")
    stream? = String.contains?(req, "\"stream\":true")

    read =
      Agent.get_and_update(reads, fn
        [h | t] -> {h, t}
        [] -> {0, []}
      end)

    payload =
      if stream? do
        sse(read)
      else
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 2,
            "cache_creation_input_tokens" => 0,
            "cache_read_input_tokens" => read
          }
        })
      end

    ct = if stream?, do: "text/event-stream", else: "application/json"

    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\nContent-Type: #{ct}\r\n" <>
        "Content-Length: #{byte_size(payload)}\r\nConnection: close\r\n\r\n" <> payload
    )

    :gen_tcp.close(socket)
  end

  defp sse(read) do
    start =
      Jason.encode!(%{
        "type" => "message_start",
        "message" => %{
          "usage" => %{
            "input_tokens" => 10,
            "cache_creation_input_tokens" => 0,
            "cache_read_input_tokens" => read
          }
        }
      })

    delta = Jason.encode!(%{"type" => "content_block_delta", "delta" => %{"text" => "ok"}})

    stop =
      Jason.encode!(%{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 2}
      })

    "event: message_start\ndata: #{start}\n\n" <>
      "event: content_block_delta\ndata: #{delta}\n\n" <>
      "event: message_delta\ndata: #{stop}\n\n" <>
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, chunk} ->
        acc = acc <> chunk

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [headers, body] ->
            len = content_length(headers)
            if byte_size(body) >= len, do: acc, else: read_all(socket, acc)

          _ ->
            read_all(socket, acc)
        end

      _ ->
        acc
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(String.downcase(line), ":", parts: 2) do
        ["content-length", v] -> v |> String.trim() |> String.to_integer()
        _ -> nil
      end
    end)
  end
end
