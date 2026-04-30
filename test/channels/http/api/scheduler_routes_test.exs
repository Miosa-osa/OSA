defmodule OptimalSystemAgent.Channels.HTTP.API.SchedulerRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.SchedulerRoutes
  alias OptimalSystemAgent.Agent.Scheduler

  @opts SchedulerRoutes.init([])

  setup do
    config_dir =
      Path.join(
        System.tmp_dir!(),
        "osa-scheduler-routes-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(config_dir)

    previous = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, config_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_system_agent, :config_dir, previous)
      else
        Application.delete_env(:optimal_system_agent, :config_dir)
      end

      File.rm_rf(config_dir)
    end)

    :ok
  end

  defp call_routes(conn) do
    SchedulerRoutes.call(conn, @opts)
  end

  defp json_get(path) do
    conn(:get, path)
    |> call_routes()
  end

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call_routes()
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "GET /presets" do
    test "returns 8 cron presets" do
      conn = json_get("/presets")
      assert conn.status == 200

      body = decode_body(conn)
      assert body["status"] == "ok"
      assert length(body["presets"]) == 8

      preset = List.first(body["presets"])
      assert is_binary(preset["id"])
      assert is_binary(preset["cron"])
      assert is_binary(preset["label"])
    end
  end

  describe "POST /:id/trigger" do
    test "runs command jobs through HeartbeatExecutor" do
      assert {:ok, job} =
               Scheduler.add_job(%{
                 "name" => "route command job",
                 "schedule" => "hourly",
                 "type" => "command",
                 "command" => "printf route-ok"
               })

      conn = json_post("/#{job["id"]}/trigger", %{})
      assert conn.status == 200

      body = decode_body(conn)
      assert body["status"] == "ok"
      assert body["run"]["status"] == "succeeded"
      assert body["run"]["stdout"] == "route-ok"

      assert :ok = Scheduler.remove_job(job["id"])
    end
  end

  describe "match _" do
    test "returns 404 for unknown endpoint" do
      conn = json_get("/nonexistent/path")
      assert conn.status == 404

      body = decode_body(conn)
      assert body["error"] == "not_found"
    end
  end
end
