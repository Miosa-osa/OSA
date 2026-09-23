defmodule OptimalSystemAgent.Security.DefenseLabIntegrationTest do
  use ExUnit.Case, async: false
  alias OptimalSystemAgent.Security.DefenseLab
  alias OptimalSystemAgent.Channels.HTTP
  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    saved =
      Map.new([:require_auth, :shared_secret], fn key ->
        {key, Application.fetch_env(:optimal_system_agent, key)}
      end)

    Application.put_env(:optimal_system_agent, :require_auth, false)
    Application.delete_env(:optimal_system_agent, :shared_secret)

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, previous} -> Application.put_env(:optimal_system_agent, key, previous)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end
    end)

    :ok
  end

  test "real isolated targets reproduce attacks, verify fixes, reject ineffective patches and clean up" do
    for mode <- ~w(apply ineffective none) do
      report =
        if mode == "apply" do
          conn =
            Plug.Test.conn(
              :post,
              "/api/v1/tools/cyber_defense/execute",
              Jason.encode!(%{arguments: %{action: "run", scenario: "all", remediation: mode}})
            )
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> HTTP.call(HTTP.init([]))

          assert conn.status == 200, conn.resp_body
          body = Jason.decode!(conn.resp_body)
          assert body["status"] == "completed"
          Jason.decode!(body["result"])
        else
          assert {:ok, report} = DefenseLab.run(%{"scenario" => "all", "remediation" => mode})
          report
        end

      assert report["verified"] == (mode == "apply")
      assert report["cleanup"] == "confirmed"

      assert report["evidence_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, report["evidence_json"]), case: :lower)

      raw_evidence = Jason.decode!(report["evidence_json"])
      assert raw_evidence["scenarios"] == report["scenarios"]
      assert raw_evidence["verified"] == report["verified"]
      assert length(report["scenarios"]) == 3

      for result <- report["scenarios"] do
        [baseline, retest] = result["phases"]
        assert baseline["attack_succeeded"]
        assert baseline["benign_control_passed"]
        assert retest["benign_control_passed"]
        assert retest["attack_succeeded"] == (mode != "apply")
        assert retest["false_alerts"] == 0
        assert result["verified"] == (mode == "apply")
      end

      {_, status} =
        System.cmd("docker", ["container", "inspect", report["container"]],
          stderr_to_stdout: true
        )

      assert status != 0, "lab container survived cleanup"
    end
  end
end
