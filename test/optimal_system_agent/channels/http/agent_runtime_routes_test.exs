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
      # Delete the per-test dir FIRST and keep deleting until it STAYS gone:
      # late runtime writers re-resolve runs_dir() and mkdir_p it back, so a
      # single rm (or an env flip) just relocates or revives the write - the
      # original ordering raised :eexist mid-traversal (CI 2026-08-26), and a
      # restore-env-first variant let stragglers fall back to the shared test
      # home where rehydrate/0 could resurrect them as phantom runs. While the
      # env still points here, any straggler lands in the dir we are watching,
      # and the poll below only returns once nothing recreated it (bounded at
      # ~1s; persistent recreation raises loudly instead of leaking silently).
      Enum.reduce_while(1..50, :ok, fn attempt, _ ->
        File.rm_rf(dir)
        Process.sleep(20)

        cond do
          not File.exists?(dir) -> {:halt, :ok}
          attempt == 50 -> raise "agent_runs_dir still being recreated after 1s: #{dir}"
          true -> {:cont, :ok}
        end
      end)

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
