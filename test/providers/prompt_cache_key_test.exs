defmodule OptimalSystemAgent.Providers.PromptCacheKeyTest do
  @moduledoc """
  A stable per-session provider cache key, asserted ON THE WIRE.

  codex keys the provider cache on the **session id** — stable for the whole
  thread, regenerated never (`prompt_cache_key` defaults to
  `responses_metadata.session_id`). That is simpler and more robust than
  keeping a derived value byte-stable, because there is no derivation to
  perturb. OSA sends the same thing.

  These assert on the serialized request body captured from a local stub, not
  on the builder's return value — a body-shaping helper that is correct but
  never reached would pass a unit test and send nothing.

  Two properties matter equally:

    * the key IS sent, and is the session id;
    * it is **stable across requests in a session** — a key regenerated per
      request is worse than no key at all, because it asserts a *different*
      cache identity every turn.

  ## Not verified against a live provider

  No OpenAI endpoint is reachable from this machine. What is proven is the
  bytes OSA puts on the wire, not that OpenAI honored them.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.{OpenAICompat, OpenAIResponses}

  @port_base 23_600

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    port = @port_base + rem(System.unique_integer([:positive]), 300)
    srv = start_stub(port, agent)

    # The gate is a host allowlist. Add the stub's host so the wire path is
    # exercised end to end rather than short-circuited.
    prev = Application.get_env(:optimal_system_agent, :prompt_cache_key_hosts)
    Application.put_env(:optimal_system_agent, :prompt_cache_key_hosts, ["127.0.0.1"])

    on_exit(fn ->
      Process.exit(srv, :kill)

      if prev,
        do: Application.put_env(:optimal_system_agent, :prompt_cache_key_hosts, prev),
        else: Application.delete_env(:optimal_system_agent, :prompt_cache_key_hosts)
    end)

    {:ok, agent: agent, base: "http://127.0.0.1:#{port}/v1"}
  end

  defp bodies(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()
  defp msgs, do: [%{role: "user", content: "hello"}]

  describe "chat completions" do
    test "the session id is sent as prompt_cache_key", %{agent: a, base: base} do
      OpenAICompat.chat(base, "sk-test", "gpt-x", msgs(), session_id: "sess-abc")

      assert [body] = bodies(a)
      assert body["prompt_cache_key"] == "sess-abc"
    end

    test "the key is IDENTICAL across every request in the session", %{agent: a, base: base} do
      for _ <- 1..3 do
        OpenAICompat.chat(base, "sk-test", "gpt-x", msgs(), session_id: "sess-stable")
      end

      keys = Enum.map(bodies(a), & &1["prompt_cache_key"])

      assert keys == ["sess-stable", "sess-stable", "sess-stable"],
             "a per-request key asserts a NEW cache identity every turn, which is " <>
               "worse than sending none: #{inspect(keys)}"
    end

    test "streaming sends the same key as non-streaming", %{agent: a, base: base} do
      OpenAICompat.chat_stream(base, "sk-test", "gpt-x", msgs(), fn _ -> :ok end,
        session_id: "sess-xyz"
      )

      assert [body] = bodies(a)
      assert body["prompt_cache_key"] == "sess-xyz"
    end

    test "an explicit :prompt_cache_key overrides the session id", %{agent: a, base: base} do
      OpenAICompat.chat(base, "sk-test", "gpt-x", msgs(),
        session_id: "sess-abc",
        prompt_cache_key: "sub-agent-scope"
      )

      assert [body] = bodies(a)
      assert body["prompt_cache_key"] == "sub-agent-scope"
    end

    test "no session id means no field at all", %{agent: a, base: base} do
      OpenAICompat.chat(base, "sk-test", "gpt-x", msgs(), [])

      assert [body] = bodies(a)
      refute Map.has_key?(body, "prompt_cache_key")
    end
  end

  describe "responses API" do
    test "the session id is sent as prompt_cache_key", %{agent: a, base: base} do
      OpenAIResponses.chat(base, "tok", "gpt-x", msgs(), session_id: "sess-resp")

      assert [body] = bodies(a)
      assert body["prompt_cache_key"] == "sess-resp"
    end
  end

  describe "the host gate" do
    test "a non-allowlisted endpoint gets no prompt_cache_key" do
      # Many OpenAI-COMPATIBLE servers 400 on unknown top-level body fields.
      # Sending the hint everywhere would trade a cache win for broken requests.
      Application.put_env(:optimal_system_agent, :prompt_cache_key_hosts, ["api.openai.com"])

      body =
        OpenAICompat.maybe_add_prompt_cache_key(
          %{model: "m"},
          [session_id: "sess"],
          "http://localhost:11434/v1"
        )

      refute Map.has_key?(body, :prompt_cache_key)

      assert OpenAICompat.prompt_cache_key_host?("https://api.openai.com/v1")
      refute OpenAICompat.prompt_cache_key_host?("https://api.deepseek.com/v1")
      refute OpenAICompat.prompt_cache_key_host?(nil)
    end
  end

  # ── stub ──────────────────────────────────────────────────────────────────

  defp start_stub(port, agent) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])

        send(parent, :stub_ready)
        accept_loop(listen, agent)
      end)

    receive do
      :stub_ready -> :ok
    after
      5_000 -> flunk("stub did not start")
    end

    pid
  end

  defp accept_loop(listen, agent) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> handle(socket, agent) end)
        accept_loop(listen, agent)

      _ ->
        :ok
    end
  end

  defp handle(socket, agent) do
    with {:ok, req} <- read_request(socket) do
      case String.split(req, "\r\n\r\n", parts: 2) do
        [_headers, body] ->
          case Jason.decode(body) do
            {:ok, decoded} -> Agent.update(agent, &[decoded | &1])
            _ -> :ok
          end

        _ ->
          :ok
      end
    end

    payload =
      Jason.encode!(%{
        "id" => "x",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}],
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
      })

    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(payload)}\r\nConnection: close\r\n\r\n" <> payload
    )

    :gen_tcp.close(socket)
  end

  # Read headers, then exactly Content-Length bytes of body.
  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, chunk} ->
        acc = acc <> chunk

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [headers, body] ->
            len = content_length(headers)

            if byte_size(body) >= len, do: {:ok, acc}, else: read_request(socket, acc)

          _ ->
            read_request(socket, acc)
        end

      _ ->
        {:ok, acc}
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(String.downcase(line), ":", parts: 2) do
        ["content-length", v] -> String.trim(v) |> String.to_integer()
        _ -> nil
      end
    end)
  end
end
