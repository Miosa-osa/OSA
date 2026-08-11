defmodule OptimalSystemAgent.MCP.EndToEndTest do
  @moduledoc """
  End-to-end MCP client tests:

    * `mcp__server__tool` execution through `Tools.Registry.execute/2` (the
      exact path `Agent.Loop.ToolExecutor` uses), verifying the result matches
      OSA's `{:ok, binary}` / `{:ok, {:image, ...}}` shapes.
    * A full `ServerSession` lifecycle (initialize → initialized → tools/list →
      tools/call) driven by a canned echo transport.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.{ServerSession, ToolBridge}
  alias OptimalSystemAgent.MCP.Config.Server
  alias OptimalSystemAgent.Tools.Registry, as: Tools

  @pt_key {OptimalSystemAgent.Tools.Registry, :mcp_tools}

  # ── Canned session (for the registry-path test) ───────────────────────

  defmodule CannedSession do
    @moduledoc false
    # ToolBridge invokes call_tool/3 (arity-3; real session has a default timeout).
    def call_tool(_server, "echo", args) do
      {:ok, %{"content" => [%{"type" => "text", "text" => args["text"] || ""}]}}
    end

    def call_tool(_server, "boom", _args) do
      {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => "kaboom"}]}}
    end
  end

  describe "mcp__ tool through Tools.Registry.execute/2" do
    setup do
      prev_session = Application.get_env(:optimal_system_agent, :mcp_server_session)
      prev_tools = :persistent_term.get(@pt_key, %{})

      Application.put_env(:optimal_system_agent, :mcp_server_session, CannedSession)

      entry =
        ToolBridge.build_tools("echo", [
          %{"name" => "echo", "description" => "echoes text", "inputSchema" => %{}},
          %{"name" => "boom", "description" => "always errors", "inputSchema" => %{}}
        ])

      :persistent_term.put(@pt_key, Map.merge(prev_tools, entry))

      on_exit(fn ->
        if prev_session,
          do: Application.put_env(:optimal_system_agent, :mcp_server_session, prev_session),
          else: Application.delete_env(:optimal_system_agent, :mcp_server_session)

        :persistent_term.put(@pt_key, prev_tools)
      end)

      :ok
    end

    test "text result normalizes to {:ok, binary}" do
      assert {:ok, "hi there"} =
               Tools.execute("mcp__echo__echo", %{"text" => "hi there"})
    end

    test "server-reported error normalizes to {:error, _}" do
      assert {:error, msg} = Tools.execute("mcp__echo__boom", %{})
      assert msg =~ "kaboom"
    end

    test "internal __session_id__ arg is stripped before forwarding" do
      # CannedSession echoes args["text"]; __session_id__ must not leak/crash.
      assert {:ok, "ok"} =
               Tools.execute("mcp__echo__echo", %{"text" => "ok", "__session_id__" => "abc"})
    end

    test "deferred mcp tools are excluded from list_active/0" do
      names = Tools.list_active() |> Enum.map(& &1.name)
      refute "mcp__echo__echo" in names

      # but they ARE present in the full (deferred-inclusive) listing
      all = Tools.list_tools_direct() |> Enum.map(& &1.name)
      assert "mcp__echo__echo" in all
    end
  end

  # ── Canned echo transport (for the ServerSession lifecycle test) ──────

  defmodule EchoTransport do
    @moduledoc false
    @behaviour OptimalSystemAgent.MCP.Transport
    use GenServer

    alias OptimalSystemAgent.MCP.Protocol.JSONRPC

    @impl true
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def send_message(pid, bin), do: GenServer.cast(pid, {:send, bin})

    @impl true
    def init(opts) do
      {:ok, %{owner: Keyword.fetch!(opts, :owner), ref: Keyword.fetch!(opts, :ref)}}
    end

    @impl true
    def handle_cast({:send, bin}, state) do
      case JSONRPC.decode(bin) do
        {:ok, {:request, id, "initialize", _}} ->
          reply(state, JSONRPC.response(id, %{"serverInfo" => %{"name" => "echo"}}))

        {:ok, {:request, id, "tools/list", _}} ->
          tools = [%{"name" => "echo", "description" => "echoes", "inputSchema" => %{}}]
          reply(state, JSONRPC.response(id, %{"tools" => tools}))

        {:ok, {:request, id, "tools/call", params}} ->
          text = get_in(params, ["arguments", "text"]) || ""

          reply(
            state,
            JSONRPC.response(id, %{"content" => [%{"type" => "text", "text" => text}]})
          )

        _ ->
          :ok
      end

      {:noreply, state}
    end

    defp reply(state, msg) do
      {:ok, json} = JSONRPC.encode(msg)
      send(state.owner, {:mcp_message, state.ref, json})
    end
  end

  describe "ServerSession lifecycle over a canned transport" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :mcp_stdio_transport)
      Application.put_env(:optimal_system_agent, :mcp_stdio_transport, EchoTransport)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :mcp_stdio_transport, prev),
          else: Application.delete_env(:optimal_system_agent, :mcp_stdio_transport)
      end)

      :ok
    end

    test "completes handshake, discovers tools, and calls a tool" do
      name = "echo_e2e_#{System.unique_integer([:positive])}"
      server = %Server{name: name, transport: :stdio, command: "irrelevant"}

      {:ok, pid} = ServerSession.start_link(server)
      # The session traps exits and is linked to this (transient) test process,
      # so it may already be terminating by cleanup time; kill tolerantly.
      #
      # The session also reports its discovered tools to the MCP Manager, which
      # rewrites the GLOBAL `{Registry, :mcp_tools}` persistent_term. That write
      # is asynchronous, so without draining it here a pending report/reload can
      # land during a LATER test and clobber the tools that test injected into
      # the same persistent_term (flaked "deferred mcp tools …"/list_active). We
      # wait for the session to actually die, then issue a synchronous
      # Manager.reload — ordered after any queued report_tools casts — so the
      # aggregate is recomputed from LIVE sessions only and nothing is left
      # in-flight to race the next test.
      on_exit(fn ->
        if Process.alive?(pid) do
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            1_000 -> :ok
          end
        end

        try do
          OptimalSystemAgent.MCP.Client.Manager.reload()
        catch
          _, _ -> :ok
        end
      end)

      assert wait_until(fn -> ServerSession.status(name) == :ready end)
      assert wait_until(fn -> ServerSession.list_tools(name) != [] end)

      assert [%{"name" => "echo"}] = ServerSession.list_tools(name)

      assert {:ok, %{"content" => [%{"type" => "text", "text" => "roundtrip"}]}} =
               ServerSession.call_tool(name, "echo", %{"text" => "roundtrip"}, 5_000)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp wait_until(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, retries - 1)
    end
  end
end
