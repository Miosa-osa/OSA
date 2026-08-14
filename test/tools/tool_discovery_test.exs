defmodule OptimalSystemAgent.Tools.ToolDiscoveryTest do
  @moduledoc """
  A deferred tool must become CALLABLE after `tool_search` finds it, not merely
  described.

  Under a provider with native tool schemas the API can only emit a `tool_use`
  block for a name present in the request's `tools` array. That array came from
  `Registry.list_active/0` and nothing ever re-added to it, so a deferred tool
  was unreachable for the whole session — and unreachable *silently*, because a
  name the API cannot emit produces no "unknown tool" error to notice.

  These tests assert the fix at the two places that matter:

    * the loop's tools array grows to include the discovered tool, survives
      `ToolFilter`'s narrowing passes, and does not thrash;
    * the array that reaches the WIRE contains it, with the tools cache
      breakpoint still on the last stable tool so the widening does not
      re-write the cached tool prefix.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolDiscovery
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Providers.Anthropic
  alias OptimalSystemAgent.Tools.Builtins.ToolSearch.Handler, as: ToolSearch
  alias OptimalSystemAgent.Tools.Registry

  @model "claude-sonnet-4-6"

  # A tool that IS registered and IS excluded from the default array. Picked at
  # runtime rather than hardcoded so a change to one tool's `should_defer?`
  # cannot turn this file vacuous — if nothing defers any more, the setup fails
  # loudly instead of passing on an empty premise.
  defp a_deferred_tool do
    active = MapSet.new(Registry.list_active(), & &1.name)

    deferred =
      Registry.list_tools_direct()
      |> Enum.reject(fn t -> MapSet.member?(active, t.name) end)
      |> Enum.sort_by(& &1.name)

    assert deferred != [],
           "no tool defers any more, so this file proves nothing; delete it or pick a new case"

    hd(deferred)
  end

  # The shape the ReAct loop hands to `ToolDiscovery.widen/2`.
  defp search_result(query) do
    [{%{id: "t1", name: "tool_search", arguments: %{"query" => query}}, {%{}, "Found 1 tool(s)"}}]
  end

  defp base_state(extra \\ %{}) do
    Map.merge(
      %{
        tools: Registry.list_active(),
        all_tools: Registry.list_active(),
        discovered_tools: [],
        messages: [],
        provider: :anthropic,
        model: @model,
        delegation_depth: 0
      },
      extra
    )
  end

  # ── The capability itself ─────────────────────────────────────────────────

  describe "a deferred tool becomes callable after discovery" do
    test "it is absent from the array before the search — the premise" do
      tool = a_deferred_tool()

      refute Enum.any?(Registry.list_active(), &(&1.name == tool.name)),
             "#{tool.name} was supposed to be deferred"

      assert Registry.module_for(tool.name) != nil or String.starts_with?(tool.name, "mcp__"),
             "#{tool.name} must still be registered — deferral hides a tool, it does not remove it"
    end

    test "a successful select: search puts it in the array" do
      tool = a_deferred_tool()
      state = base_state()

      widened = ToolDiscovery.widen(state, search_result("select:#{tool.name}"))

      names = Enum.map(widened.tools, & &1.name)
      assert tool.name in names, "the search found it and it is still not callable"

      spec = Enum.find(widened.tools, &(&1.name == tool.name))
      assert is_map(spec.parameters), "a widened entry needs its schema, not just its name"
      assert spec.description != ""
    end

    test "a keyword search widens by whatever it actually matched" do
      tool = a_deferred_tool()
      query = tool.name

      resolved = ToolSearch.resolve_tools(%{"query" => query})
      assert resolved != [], "keyword search matched nothing; pick a different probe"

      widened = ToolDiscovery.widen(base_state(), search_result(query))
      names = MapSet.new(widened.tools, & &1.name)

      for spec <- resolved do
        assert MapSet.member?(names, spec.name),
               "#{spec.name} was shown to the model but not made callable"
      end
    end

    test "the widened tool survives ToolFilter, which can otherwise only shrink" do
      tool = a_deferred_tool()

      widened = ToolDiscovery.widen(base_state(), search_result("select:#{tool.name}"))

      filtered = ToolFilter.filter(widened.tools, widened)

      assert Enum.any?(filtered, &(&1.name == tool.name)),
             "the model was told it may call #{tool.name}; the very next request dropped it"
    end

    test "a narrowing pass that drops it re-pins it" do
      tool = a_deferred_tool()

      widened = ToolDiscovery.widen(base_state(), search_result("select:#{tool.name}"))

      # Simulate a pass having removed it (the small-window budget trims to 10
      # by priority list, and a just-discovered MCP tool is never a priority).
      trimmed = Enum.reject(widened.tools, &(&1.name == tool.name))
      filtered = ToolFilter.filter(trimmed, widened)

      assert Enum.any?(filtered, &(&1.name == tool.name))
    end

    test "an unknown name widens nothing and does not crash" do
      state = base_state()
      widened = ToolDiscovery.widen(state, search_result("select:definitely_not_a_tool_xyz"))

      assert widened.tools == state.tools
      assert widened.discovered_tools == []
    end

    test "a FAILED tool_search widens nothing" do
      tool = a_deferred_tool()

      failed = [
        {%{id: "t1", name: "tool_search", arguments: %{"query" => "select:#{tool.name}"}},
         {%{}, "Error: boom"}}
      ]

      state = base_state()
      assert ToolDiscovery.widen(state, failed).tools == state.tools
    end

    test "a non-discovery tool result widens nothing" do
      state = base_state()

      other = [{%{id: "t1", name: "file_read", arguments: %{"path" => "/tmp/x"}}, {%{}, "ok"}}]

      assert ToolDiscovery.widen(state, other).tools == state.tools
    end
  end

  # ── The array must not thrash ─────────────────────────────────────────────

  describe "the array widens once and then holds still" do
    test "repeating the same search is a byte-for-byte no-op" do
      tool = a_deferred_tool()
      results = search_result("select:#{tool.name}")

      once = ToolDiscovery.widen(base_state(), results)
      twice = ToolDiscovery.widen(once, results)
      thrice = ToolDiscovery.widen(twice, results)

      assert length(once.tools) == length(twice.tools)
      assert Enum.map(twice.tools, & &1.name) == Enum.map(thrice.tools, & &1.name)

      assert Jason.encode!(strip(twice.tools)) == Jason.encode!(strip(thrice.tools)),
             "a second identical search must not move a single byte of the cached prefix"
    end

    test "widening never reorders or removes what was already there" do
      tool = a_deferred_tool()
      state = base_state()
      before = Enum.map(state.tools, & &1.name)

      widened = ToolDiscovery.widen(state, search_result("select:#{tool.name}"))
      after_names = Enum.map(widened.tools, & &1.name)

      assert Enum.take(after_names, length(before)) == before,
             "tool schemas are the FRONT of the cached prefix; new entries append, never insert"
    end

    test "two different discoveries append in name order, not call order" do
      active = MapSet.new(Registry.list_active(), & &1.name)

      [a, b | _] =
        Registry.list_tools_direct()
        |> Enum.reject(fn t -> MapSet.member?(active, t.name) end)
        |> Enum.sort_by(& &1.name)

      forwards =
        base_state()
        |> ToolDiscovery.widen(search_result("select:#{a.name},#{b.name}"))

      backwards =
        base_state()
        |> ToolDiscovery.widen(search_result("select:#{b.name},#{a.name}"))

      assert Enum.map(forwards.tools, & &1.name) == Enum.map(backwards.tools, & &1.name),
             "the appended bytes must be a function of WHICH tools were found, not of the " <>
               "order the model happened to name them"
    end

    defp strip(tools), do: Enum.map(tools, &Map.take(&1, [:name, :description, :parameters]))
  end

  # ── The wire ──────────────────────────────────────────────────────────────

  describe "under a native-tool provider the widened array reaches the request" do
    setup do
      test_pid = self()
      {server, port} = start_stub(11_811, test_pid, 0)

      prev = %{
        url: Application.get_env(:optimal_system_agent, :anthropic_url),
        key: Application.get_env(:optimal_system_agent, :anthropic_api_key)
      }

      Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:#{port}/v1")
      Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test-not-a-real-key")

      on_exit(fn ->
        restore(:anthropic_url, prev.url)
        restore(:anthropic_api_key, prev.key)
        Process.exit(server, :normal)
      end)

      :ok
    end

    test "the discovered tool is in the body's tools array" do
      tool = a_deferred_tool()
      widened = ToolDiscovery.widen(base_state(), search_result("select:#{tool.name}"))

      body = capture_body(ToolFilter.filter(widened.tools, widened))

      names = Enum.map(body["tools"], & &1["name"])

      assert tool.name in names,
             "the model can only emit a tool_use for a name in this array; #{tool.name} is " <>
               "still not one of them"

      spec = Enum.find(body["tools"], &(&1["name"] == tool.name))
      assert is_map(spec["input_schema"])
    end

    test "the cache breakpoint stays on the last STABLE tool" do
      tool = a_deferred_tool()
      base = Registry.list_active()
      widened = ToolDiscovery.widen(base_state(), search_result("select:#{tool.name}"))

      body = capture_body(widened.tools)

      marked =
        for {t, i} <- Enum.with_index(body["tools"]), Map.has_key?(t, "cache_control"), do: i

      assert marked == [length(base) - 1],
             "the breakpoint must sit at the end of the STABLE prefix. Past the appended " <>
               "tools it covers bytes that just changed, so the tools-tier cache entry the " <>
               "previous turns wrote can never be read again."
    end

    test "with nothing discovered the breakpoint is still on the last tool" do
      base = Registry.list_active()
      body = capture_body(base)

      marked =
        for {t, i} <- Enum.with_index(body["tools"]), Map.has_key?(t, "cache_control"), do: i

      assert marked == [length(base) - 1],
             "a session that discovers nothing must serialize exactly as it did before"
    end

    test "the stable prefix is byte-identical before and after a widening" do
      tool = a_deferred_tool()
      base = Registry.list_active()

      before_body = capture_body(base)
      widened = ToolDiscovery.widen(base_state(), search_result("select:#{tool.name}"))
      after_body = capture_body(widened.tools)

      assert Jason.encode!(Enum.take(before_body["tools"], length(base))) ==
               Jason.encode!(Enum.take(after_body["tools"], length(base))),
             "this identity is the whole reason the widening costs one cache write instead " <>
               "of two: the tools tier still matches, only what renders after it moved"
    end

    defp capture_body(tools) do
      messages = [
        %{role: "system", content: String.duplicate("stable system prose. ", 500)},
        %{role: "user", content: "hi"}
      ]

      Anthropic.chat(messages, model: @model, tools: tools)
      assert_receive {:captured_body, body}, 10_000
      body
    end

    defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
    defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

    defp start_stub(_base, _test_pid, attempt) when attempt > 20 do
      flunk("could not bind a stub HTTP port after 20 attempts")
    end

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
            "usage" => %{
              "input_tokens" => 1,
              "output_tokens" => 1,
              "cache_creation_input_tokens" => 0,
              "cache_read_input_tokens" => 0
            }
          })
        )
      end
    end
  end
end
