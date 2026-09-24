defmodule OptimalSystemAgent.Channels.HTTP.SessionTraceRouteTest do
  @moduledoc """
  `/trace` over the API (GET /sessions/:id/trace) and in the command surface the
  TUI renders (`trace` via the CLI command registry).
  """
  use ExUnit.Case, async: false
  use Plug.Test

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.TurnTrace
  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes

  @opts SessionRoutes.init([])

  setup do
    sid = "trace-route-#{System.unique_integer([:positive])}"
    on_exit(fn -> TurnTrace.clear(sid) end)
    %{sid: sid}
  end

  defp get(path) do
    conn(:get, path)
    |> Plug.Conn.fetch_query_params()
    |> SessionRoutes.call(@opts)
  end

  defp record_turn(sid) do
    TurnTrace.begin_turn(sid, %{model: "glm-5.2:cloud"})

    TurnTrace.record_llm(sid, %{
      duration_ms: 1_200,
      usage: %{input_tokens: 5_000, output_tokens: 300}
    })

    TurnTrace.record_tool(sid, %{
      name: "shell_execute",
      args: %{"command" => "mix test"},
      duration_ms: 800,
      success: true
    })

    TurnTrace.end_turn(sid)
  end

  test "null turn before the session has run anything", %{sid: sid} do
    conn = get("/#{sid}/trace")
    assert conn.status == 200
    assert %{"session_id" => ^sid, "turn" => nil} = Jason.decode!(conn.resp_body)
  end

  test "serves the latest turn, and every retained turn with ?all=1", %{sid: sid} do
    record_turn(sid)
    record_turn(sid)

    body = get("/#{sid}/trace") |> Map.get(:resp_body) |> Jason.decode!()
    turn = body["turn"]
    assert turn["turn"] == 2
    assert turn["status"] == "done"
    assert turn["model"] == "glm-5.2:cloud"
    assert turn["breakdown"]["model_ms"] == 1_200
    assert turn["llm"]["input_tokens"] == 5_000
    assert [%{"name" => "shell_execute", "calls" => 1}] = turn["tools"]["per_tool"]
    refute Map.has_key?(body, "turns")

    all = get("/#{sid}/trace?all=1") |> Map.get(:resp_body) |> Jason.decode!()
    assert Enum.map(all["turns"], & &1["turn"]) == [2, 1]
  end

  test "the trace command prints the compact table", %{sid: sid} do
    record_turn(sid)

    out = capture_io(fn -> Commands.dispatch("trace", sid) end)
    assert out =~ "Turn 1 · done"
    assert out =~ ~r/model\s+1\.2s/
    assert out =~ "shell_execute"
    assert out =~ "mix test"

    assert capture_io(fn -> Commands.dispatch("trace", "never-ran-#{sid}") end) =~
             "No turn recorded"

    assert {"trace", _} = Enum.find(Commands.list_with_descriptions(), &(elem(&1, 0) == "trace"))
  end
end
