defmodule OptimalSystemAgent.Agent.Loop.WS1PermissionHotfixTest do
  @moduledoc """
  WS1 P0 regression coverage:
    * legacy `{allowed: bool}` /respond payloads map onto canonical decisions
    * non-interactive channels FAIL CLOSED unless the explicit bypass is set
    * saved deny rules beat the :overdrive / :accept_edits short-circuits
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes
  alias OptimalSystemAgent.Permissions

  @route_opts ToolRoutes.init([])

  setup do
    file = Application.get_env(:optimal_system_agent, :permissions_file)
    if is_binary(file), do: File.rm(file)

    prior = Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, prior)
    end)

    :ok
  end

  defp state(overrides \\ []) do
    struct(Loop, [session_id: "ws1-#{System.unique_integer([:positive])}"] ++ overrides)
  end

  defp tool(name, args \\ %{}),
    do: %{id: "tc-#{System.unique_integer([:positive])}", name: name, arguments: args}

  defp post_respond(body) do
    conn(:post, "/respond", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> ToolRoutes.call(@route_opts)
  end

  defp legacy_round_trip(body) do
    rid = PermissionBroker.new_request_id()
    # `attended: true` — see Agent.Attendance; this synthetic session has no
    # registered channel and the legacy payload mapping is what is under test.
    task =
      Task.async(fn ->
        PermissionBroker.await("ws1-sess", rid, timeout: 5_000, attended: true)
      end)

    Process.sleep(50)
    conn = post_respond(Map.put(body, :request_id, rid))
    assert conn.status == 200
    assert {:ok, decision} = Task.await(task, 6_000)
    decision
  end

  describe "legacy {allowed: bool} payload mapping" do
    test "allowed: true -> allow_once" do
      assert %{decision: :allow_once} = legacy_round_trip(%{allowed: true})
    end

    test "allowed: false -> deny" do
      assert %{decision: :deny} = legacy_round_trip(%{allowed: false})
    end

    test "allowed: true + allow_always -> allow_always" do
      assert %{decision: :allow_always} = legacy_round_trip(%{allowed: true, allow_always: true})
    end

    test "allowed: false + allow_always -> deny_always" do
      assert %{decision: :deny_always} = legacy_round_trip(%{allowed: false, allow_always: true})
    end

    test "canonical decision string still wins" do
      assert %{decision: :allow_session} =
               legacy_round_trip(%{decision: "session", allowed: false})
    end
  end

  describe "non-interactive fail-closed" do
    test "mutating tool is auto-rejected without the bypass" do
      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), state())

      assert msg =~ "auto-rejected"
    end

    test "explicit bypass restores auto-allow (test suite behaviour)" do
      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, true)

      assert :allow =
               ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), state())
    end

    test "read-only tool never prompts, so it stays allowed either way" do
      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

      assert :allow =
               ToolExecutor.approve_tool_call(tool("file_read", %{"path" => "a.txt"}), state())
    end
  end

  describe "deny rules beat mode short-circuits" do
    test "saved deny rule blocks in :overdrive" do
      Permissions.save_rule("file_write", :deny_always)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "a.txt"}),
                 state(permission_mode: :overdrive)
               )

      assert msg =~ "denied by a saved permission rule"
    end

    test "saved deny rule blocks in :accept_edits" do
      Permissions.save_rule("file_edit", :deny_always)

      assert {:blocked, _} =
               ToolExecutor.approve_tool_call(
                 tool("file_edit", %{"old_string" => "a", "new_string" => "b"}),
                 state(permission_mode: :accept_edits)
               )
    end

    test "no deny rule -> :overdrive still allows" do
      assert :allow =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "a.txt"}),
                 state(permission_mode: :overdrive)
               )
    end
  end
end
