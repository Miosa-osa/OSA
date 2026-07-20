defmodule OptimalSystemAgent.Agent.CoordinatorModeTest do
  @moduledoc """
  Coverage for the coordinator posture exposed to the Rust TUI:

    * the sticky per-session `CoordinatorMode` store (get/put/default),
    * the in-place `Loop` toggle flipping BOTH `state.coordinator` and the live
      `state.tools` (restricted when on, full base list restored when off),
    * a `coordinator_mode` system_event reaching the TUI via the forwarder
      allowlist.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Agent.CoordinatorMode
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes

  @route_opts ToolRoutes.init([])

  defp exec(command, arg, session_id) do
    conn(:post, "/execute", Jason.encode!(%{command: command, arg: arg, session_id: session_id}))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> ToolRoutes.call(@route_opts)
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp sid, do: "coord-#{System.unique_integer([:positive])}"

  # A base tool list mixing coordinator-allowlisted tools with execution tools,
  # mirroring what init captures on `state.all_tools`.
  defp base_tools do
    ~w(delegate send_message memory_recall file_write shell_execute file_read)
    |> Enum.map(&%{name: &1})
  end

  describe "sticky store" do
    test "defaults to false for an unknown session" do
      refute CoordinatorMode.get(sid())
    end

    test "put then get round-trips the flag" do
      id = sid()
      assert :ok = CoordinatorMode.put(id, true)
      assert CoordinatorMode.get(id) == true

      assert :ok = CoordinatorMode.put(id, false)
      assert CoordinatorMode.get(id) == false
    end

    test "clear forgets the flag (back to default false)" do
      id = sid()
      CoordinatorMode.put(id, true)
      assert :ok = CoordinatorMode.clear(id)
      refute CoordinatorMode.get(id)
    end

    test "non-binary session ids are ignored, never crash" do
      assert :ok = CoordinatorMode.put(nil, true)
      assert CoordinatorMode.get(nil) == false
    end
  end

  describe "in-place Loop toggle" do
    defp state(overrides \\ []) do
      struct(Loop, [session_id: sid(), all_tools: base_tools(), tools: base_tools()] ++ overrides)
    end

    test "turning coordinator ON restricts state.tools to the allowlist" do
      {:reply, {:ok, true}, new} = Loop.handle_call({:set_coordinator, true}, self(), state())

      assert new.coordinator == true
      names = Enum.map(new.tools, & &1.name)
      assert "delegate" in names
      assert "send_message" in names
      assert "memory_recall" in names
      refute "file_write" in names
      refute "shell_execute" in names
    end

    test "turning coordinator OFF restores the full base tool list" do
      # Start restricted (as if it were toggled on earlier).
      on_state =
        state(coordinator: true, tools: [%{name: "delegate"}, %{name: "send_message"}])

      {:reply, {:ok, false}, off} =
        Loop.handle_call({:set_coordinator, false}, self(), on_state)

      assert off.coordinator == false
      # Full base list is back, execution tools included.
      assert Enum.map(off.tools, & &1.name) == Enum.map(base_tools(), & &1.name)
    end

    test "get_coordinator reflects the live state" do
      {:reply, {:ok, true}, _} =
        Loop.handle_call({:get_coordinator}, self(), state(coordinator: true))
    end
  end

  describe "coordinator_mode forwarding" do
    test "coordinator_mode (allowlisted) is bridged from the Bus to the session topic" do
      id = "coord-fwd-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{id}")

      OptimalSystemAgent.Events.Bus.emit(:system_event, %{
        event: :coordinator_mode,
        session_id: id,
        active: true
      })

      assert_receive {:osa_event, %{type: :system_event, event: :coordinator_mode, active: true}},
                     2000
    end
  end

  describe "POST /execute coordinator arm" do
    test "on / off / toggle dispatch and return the resulting state" do
      id = sid()

      on = exec("coordinator", "on", id)
      assert on["active"] == true
      assert on["command"] == "coordinator"
      assert on["output"] =~ "ON"
      assert CoordinatorMode.get(id) == true

      off = exec("coordinator", "off", id)
      assert off["active"] == false
      assert off["output"] =~ "OFF"
      assert CoordinatorMode.get(id) == false

      toggled = exec("coordinator", "toggle", id)
      assert toggled["active"] == true
      assert CoordinatorMode.get(id) == true
    end

    test "status reads the sticky state without changing it" do
      id = sid()
      CoordinatorMode.put(id, true)

      status = exec("coordinator", "status", id)
      assert status["active"] == true
      assert CoordinatorMode.get(id) == true
    end
  end
end
