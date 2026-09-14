defmodule OptimalSystemAgent.Security.DefenseLabIntegrationTest do
  use ExUnit.Case, async: false
  alias OptimalSystemAgent.Security.DefenseLab
  alias OptimalSystemAgent.Tools.Registry
  @moduletag :integration
  @moduletag timeout: 120_000

  test "real isolated targets reproduce attacks, verify fixes, reject ineffective patches and clean up" do
    for mode <- ~w(apply ineffective none) do
      report =
        if mode == "apply" do
          assert {:ok, json} =
                   Registry.execute_direct("cyber_defense", %{
                     "action" => "run",
                     "scenario" => "all",
                     "remediation" => mode
                   })

          Jason.decode!(json)
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
