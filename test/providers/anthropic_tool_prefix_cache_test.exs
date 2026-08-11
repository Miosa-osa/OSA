defmodule OptimalSystemAgent.Providers.AnthropicToolPrefixCacheTest do
  @moduledoc """
  Guards the TOOLS half of the Anthropic cached prefix.

  `anthropic_system_cache_test.exs` covers the `system` array — the ~32k-token
  static base and the volatile tail that must stay outside every cached region.
  This file covers what renders BEFORE it.

  Anthropic renders a request as `tools` -> `system` -> `messages`, and prompt
  caching is a prefix match. That makes the tool definitions the first bytes of
  the cached prefix and, at ~62 KB / ~15.5k tokens on a default OSA session,
  roughly a third of it. Two properties therefore have to hold, and neither did:

    1. **The order is deterministic.** Both halves of the tool list came out of
       `Enum.map` over a MAP. Erlang leaves map iteration order unspecified — it
       follows the key set and the runtime's internal hashing, with no stability
       guarantee across OTP versions. The tool list is the very front of the
       cached prefix, so an order that is not a pure function of the tool names
       is a prefix that can move for reasons invisible in any diff.

    2. **The tools have their own breakpoint.** They were cached only as part of
       the system segment, because the first `system` marker covers everything
       before it. Anthropic's invalidation hierarchy is tiered: a system-prompt
       change invalidates the system cache and leaves the tools cache intact —
       but only if a tools breakpoint exists to define that tier. Without one,
       editing a rules file or connecting an MCP server re-wrote all ~48k tokens
       at the 1.25x write rate rather than re-writing the ~32k that changed.

  Context uses 2 of Anthropic's 4 breakpoints, so the tools breakpoint is free.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Anthropic
  alias OptimalSystemAgent.Tools.Registry

  @model "claude-sonnet-4-6"
  @api_breakpoint_limit 4

  setup do
    test_pid = self()
    {server, port} = start_stub(11_701, test_pid, 0)

    prev = %{
      url: Application.get_env(:optimal_system_agent, :anthropic_url),
      key: Application.get_env(:optimal_system_agent, :anthropic_api_key),
      caching: Application.get_env(:optimal_system_agent, :prompt_caching_enabled)
    }

    Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:#{port}/v1")
    Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test-not-a-real-key")

    on_exit(fn ->
      restore(:anthropic_url, prev.url)
      restore(:anthropic_api_key, prev.key)
      restore(:prompt_caching_enabled, prev.caching)
      Process.exit(server, :normal)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  # ── Ordering determinism ──────────────────────────────────────────────────

  describe "the tool list is ordered by name, not by map iteration" do
    test "builtin tools come out sorted" do
      names =
        Registry.list_tools_direct()
        |> Enum.map(& &1.name)
        |> Enum.reject(&String.starts_with?(&1, "mcp__"))

      assert names != [], "registry produced no builtin tools; the assertion below is vacuous"

      assert names == Enum.sort(names),
             "tool definitions render FIRST in an Anthropic request, so this list is the " <>
               "front of the cached prefix. Map iteration order is unspecified in Erlang; " <>
               "sorting by name is what makes the prefix reproducible.\ngot: #{inspect(names)}"
    end

    test "the model-facing active set is sorted too" do
      names = Registry.list_active() |> Enum.map(& &1.name)

      assert names != []
      assert names == Enum.sort(names)
    end

    # REGRESSION GUARD, not a fix. `{{TOOL_DEFINITIONS}}` is interpolated into
    # `Soul.static_base/0` — the single largest cached block — and reaches it via
    # `ToolsSection.fetch_builtin_modules/0`, which iterates an UNORDERED map.
    # The output is nonetheless deterministic today only because
    # `PromptAssembler.assemble/3` happens to sort by name before rendering.
    # That sort is load-bearing for the prompt cache and nothing said so; this
    # pins it, so removing it fails here instead of silently costing ~32k tokens
    # of cache reads per turn.
    test "the prose tool block in the STATIC BASE is ordered by name" do
      section = OptimalSystemAgent.Soul.ToolsSection.build()

      # Headings look like `## ask_user (aliases: ask, question)` — the alias
      # suffix is optional, so do NOT anchor the end of the line or the match
      # silently narrows to the handful of tools that declare no aliases.
      known = MapSet.new(Registry.list_tools_direct(), & &1.name)

      headings =
        Regex.scan(~r/^## ([a-z][a-z0-9_]*)/m, section || "")
        |> Enum.map(fn [_, name] -> name end)
        |> Enum.filter(&MapSet.member?(known, &1))

      assert length(headings) > 20,
             "expected the prose tool section to list most tools as `## name` headings; " <>
               "got #{length(headings)}"

      assert headings == Enum.sort(headings),
             "the static base is the largest cached block; its tool order must be a pure " <>
               "function of the tool names.\ngot: #{inspect(headings)}"
    end
  end

  # ── The tools breakpoint ──────────────────────────────────────────────────

  describe "tool definitions carry their own cache breakpoint" do
    test "the LAST tool definition is marked, and only the last" do
      body = capture_body_with_tools(sample_tools())

      assert is_list(body["tools"])
      marked = Enum.filter(body["tools"], &Map.has_key?(&1, "cache_control"))

      assert length(marked) == 1,
             "exactly one breakpoint closes the tools segment; got #{length(marked)}"

      assert List.last(body["tools"]) == List.last(marked),
             "the marker must sit on the LAST tool — a breakpoint caches the prefix " <>
               "ENDING at it, so marking anything earlier leaves the remaining tools " <>
               "outside the cached region"

      assert List.last(body["tools"])["cache_control"] == %{"type" => "ephemeral"}
    end

    test "the marker survives alongside the system blocks and stays within the API limit" do
      body = capture_body_with_tools(sample_tools())

      tool_marks = Enum.count(body["tools"], &Map.has_key?(&1, "cache_control"))

      system_marks =
        case body["system"] do
          blocks when is_list(blocks) -> Enum.count(blocks, &Map.has_key?(&1, "cache_control"))
          _ -> 0
        end

      assert tool_marks >= 1
      assert system_marks >= 1, "the system blocks must keep their own breakpoints"

      assert tool_marks + system_marks <= @api_breakpoint_limit,
             "Anthropic rejects more than #{@api_breakpoint_limit} breakpoints per request; " <>
               "got #{tool_marks} on tools + #{system_marks} on system"
    end

    test "a caller with a full system array loses a SYSTEM marker, never the tools one" do
      # Tools render first, so the tools marker covers the longest stable prefix
      # of any marker in the request. When the budget is exhausted it is the
      # LATEST markers that must go.
      system_blocks =
        Enum.map(1..5, fn i ->
          %{
            type: "text",
            text: String.duplicate("system block #{i} ", 400),
            cache_control: %{type: "ephemeral"}
          }
        end)

      body =
        capture_body_with_tools(
          sample_tools(),
          [%{role: "system", content: system_blocks}, %{role: "user", content: "hi"}]
        )

      tool_marks = Enum.count(body["tools"], &Map.has_key?(&1, "cache_control"))
      system_marks = Enum.count(body["system"], &Map.has_key?(&1, "cache_control"))

      assert tool_marks == 1, "the tools breakpoint covers the longest prefix; it must survive"
      assert tool_marks + system_marks == @api_breakpoint_limit
      assert system_marks == 3

      # Earliest system markers kept, latest dropped.
      kept =
        for {b, i} <- Enum.with_index(body["system"]), Map.has_key?(b, "cache_control"), do: i

      assert kept == [0, 1, 2]
    end

    test "no breakpoint when prompt caching is switched off" do
      Application.put_env(:optimal_system_agent, :prompt_caching_enabled, false)
      body = capture_body_with_tools(sample_tools())

      refute Enum.any?(body["tools"], &Map.has_key?(&1, "cache_control")),
             "prompt_caching_enabled: false must leave the wire free of every marker"
    end

    test "a tool list too small to cache does not spend a breakpoint" do
      # Below Anthropic's minimum cacheable prefix a marker silently does
      # nothing — no error, no cache entry — so it would only waste one of four.
      tiny = [%{name: "x", description: "y", parameters: %{"type" => "object"}}]
      body = capture_body_with_tools(tiny)

      refute Enum.any?(body["tools"], &Map.has_key?(&1, "cache_control"))
    end
  end

  # ── Byte identity ─────────────────────────────────────────────────────────

  describe "the tools segment is byte-identical across requests" do
    test "two requests a second apart serialize the tools array identically" do
      tools = sample_tools()

      first = capture_body_with_tools(tools)
      Process.sleep(1_100)
      second = capture_body_with_tools(tools)

      assert Jason.encode!(first["tools"]) == Jason.encode!(second["tools"]),
             "the tools array is the front of the cached prefix — a single byte of " <>
               "per-request variance here invalidates the ENTIRE prefix behind it"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Real registry tools: this is the payload that actually ships, so the size
  # threshold and the serialization are exercised against production data.
  defp sample_tools, do: Registry.list_active()

  defp capture_body_with_tools(tools, messages \\ nil) do
    messages =
      messages ||
        [
          %{role: "system", content: String.duplicate("stable system prose. ", 500)},
          %{role: "user", content: "hi"}
        ]

    Anthropic.chat(messages, model: @model, tools: tools)
    assert_receive {:captured_body, body}, 10_000
    body
  end

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
