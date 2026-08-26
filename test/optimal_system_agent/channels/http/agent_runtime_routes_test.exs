defmodule OptimalSystemAgent.Channels.HTTP.API.AgentRuntimeRoutesTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias OptimalSystemAgent.Agent.ExecutionControl
  alias OptimalSystemAgent.Channels.HTTP.API.AgentManagementRoutes

  @opts AgentManagementRoutes.init([])

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "osa-agent-runtime-route-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:optimal_system_agent, :agent_runs_dir, previous),
        else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)
    end)

    :ok
  end

  test "GET /:id/runtime returns the durable subagent control projection" do
    :ok =
      ExecutionControl.start("worker", %{
        parent_session_id: "parent",
        task: "Inspect the failure",
        model_reason: "tools required",
        skill_reason: "diagnose matched"
      })

    conn = AgentManagementRoutes.call(conn(:get, "/worker/runtime"), @opts)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert body["task"] == "Inspect the failure"
    assert body["model_reason"] == "tools required"
    assert "cancel_tool" in body["available_controls"]
  end

  test "unknown runtime records return 404" do
    conn = AgentManagementRoutes.call(conn(:get, "/missing/runtime"), @opts)
    assert conn.status == 404
  end

  test "POST /:id/control rejects unsupported actions without mutating the run" do
    :ok = ExecutionControl.start("worker", %{task: "Inspect the failure"})

    conn =
      :post
      |> conn("/worker/control")
      |> Map.put(:body_params, %{"action" => "teleport"})
      |> AgentManagementRoutes.call(@opts)

    body = Jason.decode!(conn.resp_body)
    assert conn.status == 400
    assert body["error"] =~ "unsupported_action"
    assert ExecutionControl.get("worker").status == "running"
  end
end
