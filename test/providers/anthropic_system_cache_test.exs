defmodule OptimalSystemAgent.Providers.AnthropicSystemCacheTest do
  @moduledoc """
  Guards the Anthropic prompt-cache structure END TO END, on the wire.

  `Agent.Context.build_system_message/4` deliberately emits THREE system content
  blocks with TWO `cache_control` breakpoints:

      1. static base   — cached (never changes within a session)
      2. world state   — cached (diffed; byte-identical unless a section changed)
      3. volatile      — UNCACHED (clock, turn count, working tree, recall)

  `test/agent/context_test.exs` asserted that structure existed and passed —
  while the provider flattened all three blocks into one string and re-wrapped
  the result as a SINGLE cached block. That put `Context.runtime_block/1`'s
  timestamp inside the cached region, making every request byte-unique and the
  cache hit rate a hard 0%.

  So these tests do not assert on the builder's output. They assert on the
  serialized request body captured from a local Bandit stub — the only place
  the defect was observable. The load-bearing test is
  "the cached prefix is byte-identical across two requests": that is the actual
  success criterion for prompt caching, and it is what nothing asserted before.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Anthropic

  # 4.6+ / Claude 5 model: prefill unsupported, so this also exercises the
  # v1.0.50 trailing-user normalization alongside the cache structure.
  @model "claude-sonnet-4-6"

  # Anthropic's documented per-request limit.
  @api_breakpoint_limit 4

  setup do
    test_pid = self()
    {server, port} = start_stub(11_501, test_pid, 0)

    prev = %{
      url: Application.get_env(:optimal_system_agent, :anthropic_url),
      key: Application.get_env(:optimal_system_agent, :anthropic_api_key),
      provider: Application.get_env(:optimal_system_agent, :default_provider)
    }

    Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:#{port}/v1")
    Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test-not-a-real-key")
    Application.put_env(:optimal_system_agent, :default_provider, :anthropic)

    on_exit(fn ->
      restore(:anthropic_url, prev.url)
      restore(:anthropic_api_key, prev.key)
      restore(:default_provider, prev.provider)
      Process.exit(server, :normal)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "cache-test-#{:erlang.unique_integer([:positive])}",
        channel: :cli,
        messages: [%{role: "user", content: "what model are you?"}],
        plan_mode: false,
        working_dir: "/tmp"
      },
      overrides
    )
  end

  # Drive the real path: Context.build/1 -> Anthropic.chat/2 -> captured body.
  defp capture_body(state) do
    %{messages: messages} = OptimalSystemAgent.Agent.Context.build(state)
    Anthropic.chat(messages, model: @model)
    assert_receive {:captured_body, body}, 10_000
    body
  end

  defp breakpoints(blocks) when is_list(blocks),
    do: Enum.filter(blocks, &Map.has_key?(&1, "cache_control"))

  # Everything the provider will serve from cache: all blocks up to and
  # including the LAST one carrying a breakpoint. Anthropic caches the prefix
  # ending at each marker, so this is exactly the region that must be stable.
  defp cached_prefix(blocks) when is_list(blocks) do
    last_marked =
      blocks
      |> Enum.with_index()
      |> Enum.filter(fn {b, _i} -> Map.has_key?(b, "cache_control") end)
      |> List.last()

    case last_marked do
      nil -> []
      {_b, idx} -> Enum.take(blocks, idx + 1)
    end
  end

  # ── The blocks survive the provider ───────────────────────────────────────

  describe "system prompt reaches the wire as a block array" do
    test "system is an ARRAY of content blocks, not a flattened string" do
      body = capture_body(base_state())

      assert is_list(body["system"]),
             "the provider flattened Context's multi-block system prompt back into a string — " <>
               "that is the defect this test exists to catch"

      assert length(body["system"]) >= 2
      assert Enum.all?(body["system"], &(&1["type"] == "text"))
    end

    test "the static base carries the first ephemeral breakpoint" do
      body = capture_body(base_state())
      first = List.first(body["system"])

      assert first["cache_control"] == %{"type" => "ephemeral"},
             "the largest stable prefix must be cached first"

      assert first["text"] != ""
    end

    test "breakpoints are ordered largest-stable-prefix first" do
      body = capture_body(base_state())
      blocks = body["system"]
      marked_idx = for {b, i} <- Enum.with_index(blocks), Map.has_key?(b, "cache_control"), do: i

      assert marked_idx != [], "no cache breakpoint reached the wire at all"

      assert List.first(marked_idx) == 0,
             "the first block (static base) must carry a breakpoint, or the stable prefix is uncached"

      assert marked_idx == Enum.sort(marked_idx)
    end

    test "the trailing volatile block is NOT inside a cached region" do
      body = capture_body(base_state())
      blocks = body["system"]

      # Context emits the volatile tail last and uncached. If a breakpoint lands
      # on the final block, everything volatile is inside the cached prefix and
      # the cache can never hit.
      refute Map.has_key?(List.last(blocks), "cache_control"),
             "the final (volatile) block must not carry a cache breakpoint"
    end
  end

  # ── The actual success criterion: byte-identity ───────────────────────────

  describe "cached prefix is byte-identical across requests" do
    test "two requests one second apart in the same session share an identical cached prefix" do
      state = base_state()

      first = capture_body(state)
      # A full second, so a second-resolution clock genuinely ticks. If the
      # timestamp were inside the cached region this is what would break.
      Process.sleep(1_100)
      second = capture_body(state)

      prefix_1 = cached_prefix(first["system"])
      prefix_2 = cached_prefix(second["system"])

      assert prefix_1 != [], "nothing was marked cacheable"

      assert Jason.encode!(prefix_1) == Jason.encode!(second["system"] |> cached_prefix()),
             "the cached prefix differs between two consecutive requests — the cache can never hit"

      assert prefix_1 == prefix_2
    end

    test "the volatile tail DOES change between those requests" do
      state = base_state()

      first = capture_body(state)
      Process.sleep(1_100)
      second = capture_body(state)

      tail_1 = List.last(first["system"])["text"]
      tail_2 = List.last(second["system"])["text"]

      assert tail_1 != tail_2,
             "precondition: the volatile block really does vary per request, so the " <>
               "byte-identity of the cached prefix above is a meaningful result and not " <>
               "an artifact of a fully static prompt"
    end
  end

  # ── Nothing that varies may sit inside a cached block ─────────────────────

  describe "no per-request value appears inside a cached block" do
    test "timestamp, session id and turn count are absent from every cached block" do
      state = base_state(%{session_id: "sentinel-session-id-9f3a", turn_count: 7})
      body = capture_body(state)

      cached_text = cached_prefix(body["system"]) |> Enum.map_join("\n", & &1["text"])

      refute cached_text =~ "sentinel-session-id-9f3a",
             "the session id varies per session and must live after the last breakpoint"

      refute cached_text =~ ~r/^- Timestamp:/m,
             "a clock inside a cached block makes every request byte-unique"

      refute cached_text =~ ~r/^- Turn: /m,
             "the turn count changes every turn and must stay uncached"

      # And prove those values really are present, just in the uncached tail.
      tail = List.last(body["system"])["text"]
      assert tail =~ "sentinel-session-id-9f3a"
      assert tail =~ "- Timestamp:"
    end

    test "the timestamp is second-resolution, carrying no microsecond entropy" do
      body = capture_body(base_state())
      tail = List.last(body["system"])["text"]

      assert [_, stamp] = Regex.run(~r/- Timestamp: (\S+)/, tail)

      refute stamp =~ ~r/\.\d+Z$/,
             "a microsecond timestamp is pure per-request entropy: #{stamp}"

      assert {:ok, _, _} = DateTime.from_iso8601(stamp)
    end
  end

  # ── API limits ────────────────────────────────────────────────────────────

  describe "breakpoint budget" do
    test "the emitted system array stays within Anthropic's 4-breakpoint limit" do
      body = capture_body(base_state())

      assert length(breakpoints(body["system"])) <= @api_breakpoint_limit
    end

    test "the whole request body stays within the limit, counting every field" do
      body = capture_body(base_state())

      count =
        body
        |> Jason.encode!()
        |> then(&Regex.scan(~r/"cache_control"/, &1))
        |> length()

      assert count <= @api_breakpoint_limit,
             "#{count} cache_control markers in one request; the API rejects more than " <>
               "#{@api_breakpoint_limit}"
    end

    test "a caller exceeding the limit has its LATEST markers dropped, not its earliest" do
      # Earliest markers cover the longest stable prefix, so they are the ones
      # worth keeping. Six marked blocks in, at most four out, and the survivors
      # must be the first four.
      blocks =
        for i <- 1..6 do
          %{type: "text", text: "block #{i} " <> String.duplicate("x", 200)}
          |> Map.put(:cache_control, %{type: "ephemeral"})
        end

      body = capture_body_for_system(blocks)
      marked = breakpoints(body["system"])

      assert length(marked) == @api_breakpoint_limit
      assert Enum.map(marked, & &1["text"]) == Enum.map(Enum.take(body["system"], 4), & &1["text"])
    end
  end

  # ── Caching can still be switched off wholesale ───────────────────────────

  describe "prompt_caching_enabled? = false" do
    test "strips every breakpoint but keeps the block structure intact" do
      prev = Application.get_env(:optimal_system_agent, :prompt_caching_enabled)
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, false)

      try do
        body = capture_body(base_state())

        assert is_list(body["system"])
        assert breakpoints(body["system"]) == []
      after
        restore(:prompt_caching_enabled, prev)
      end
    end
  end

  # ── The v1.0.50 prefill contract still holds on the block path ────────────

  describe "prefill semantics are unchanged by the block path" do
    test "a plain string system message still goes out as a string" do
      Anthropic.chat(
        [
          %{role: "system", content: "You are OSA."},
          %{role: "user", content: "hi"}
        ],
        model: @model
      )

      assert_receive {:captured_body, body}, 10_000

      assert body["system"] == "You are OSA.",
             "callers that send a plain system string must keep the exact wire shape they had"
    end

    test "block-mode system prompts still end the conversation with a user turn" do
      state = base_state(%{messages: [%{role: "user", content: "hi"}]})
      %{messages: messages} = OptimalSystemAgent.Agent.Context.build(state)

      # Append the exact shape that produced the v1.0.50 400: assistant text
      # followed by a mid-turn system nudge.
      messages =
        messages ++
          [
            %{role: "assistant", content: "I would now edit the file"},
            %{role: "system", content: "[System: you did not call any tools. EXECUTE now.]"}
          ]

      Anthropic.chat(messages, model: @model)
      assert_receive {:captured_body, body}, 10_000

      assert List.last(body["messages"])["role"] == "user"

      refute Enum.any?(body["messages"], &(&1["role"] == "system")),
             "a mid-conversation role:system message 400s on this model"

      assert is_list(body["system"]),
             "the mid-turn nudge must not have collapsed the cache block structure"
    end
  end

  # ── The streaming path is the one production actually uses ────────────────

  describe "chat_stream/3 emits the same cache structure" do
    test "the streamed request body carries the block array and its breakpoints" do
      state = base_state()
      %{messages: messages} = OptimalSystemAgent.Agent.Context.build(state)

      # Run the call in its OWN process: `chat_stream/3` uses `into: :self`, so
      # Req delivers the response chunks to the caller's mailbox and
      # `collect_stream/3` drains it — inside the test process that also eats
      # the stub's `{:captured_body, _}` message before assert_receive sees it.
      Task.start(fn -> Anthropic.chat_stream(messages, fn _ -> :ok end, model: @model) end)

      assert_receive {:captured_body, body}, 10_000

      assert body["stream"] == true

      assert is_list(body["system"]),
             "chat_stream/3 shares split_system/2 with chat/2 — both must keep the blocks"

      assert length(breakpoints(body["system"])) in 1..@api_breakpoint_limit
      refute Map.has_key?(List.last(body["system"]), "cache_control")
    end
  end

  # ── Stub plumbing ─────────────────────────────────────────────────────────

  defp capture_body_for_system(blocks) do
    Anthropic.chat(
      [%{role: "system", content: blocks}, %{role: "user", content: "hi"}],
      model: @model
    )

    assert_receive {:captured_body, body}, 10_000
    body
  end

  defp start_stub(_base, _test_pid, attempt) when attempt > 20 do
    flunk("could not bind a stub HTTP port after 20 attempts")
  end

  defp start_stub(base, test_pid, attempt) do
    port = base + attempt

    # Probe first: Bandit.start_link/1 LINKS, so an :eaddrinuse kills the test
    # process instead of returning {:error, _} — it cannot be rescued inline.
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

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, raw, conn} = read_body(conn)
      send(test_pid, {:captured_body, Jason.decode!(raw)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      )
    end
  end
end
