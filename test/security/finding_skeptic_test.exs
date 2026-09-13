defmodule OptimalSystemAgent.Security.FindingSkepticTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.FindingSkeptic

  @independent %{
    validation_verdict: :confirmed,
    validation_status: :completed,
    validator_id: "agent-val-1",
    poc: "id=1 OR 1=1"
  }

  describe "independent?/1" do
    test "parent-confirmed with poc but no validator_id is not independent" do
      f = %{status: :confirmed, poc: "id=1 OR 1=1", validation_verdict: :confirmed}
      refute FindingSkeptic.independent?(f)
    end

    test "completed confirmed with validator_id + poc is independent" do
      assert FindingSkeptic.independent?(@independent)
    end

    test "nil status is independent when verdict is confirmed and validator_id is present" do
      f = Map.put(@independent, :validation_status, nil)
      assert FindingSkeptic.independent?(f)
    end

    test "rejected verdict is not independent" do
      f = Map.put(@independent, :validation_verdict, :rejected)
      refute FindingSkeptic.independent?(f)
    end

    test "timeout is not independent" do
      refute FindingSkeptic.independent?(Map.merge(@independent, %{validation_verdict: :timeout}))

      refute FindingSkeptic.independent?(Map.merge(@independent, %{validation_status: :timeout}))
    end

    test "failed, canceled, and inconclusive verdicts are not independent" do
      for verdict <- [:failed, :canceled, :inconclusive, nil] do
        refute FindingSkeptic.independent?(Map.put(@independent, :validation_verdict, verdict)),
               "expected #{inspect(verdict)} not to be independent"
      end
    end

    test "empty validator_id is parent self-confirm" do
      refute FindingSkeptic.independent?(Map.put(@independent, :validator_id, ""))
      refute FindingSkeptic.independent?(Map.put(@independent, :validator_id, nil))
    end

    test "string keys work" do
      f = %{
        "validation_verdict" => "confirmed",
        "validation_status" => "completed",
        "validator_id" => "agent-val-1",
        "poc" => "id=1 OR 1=1"
      }

      assert FindingSkeptic.independent?(f)
    end
  end

  describe "promote/1" do
    test "parent-confirmed with poc but no validator_id errors include missing validator" do
      f = %{status: :confirmed, poc: "id=1 OR 1=1", validation_verdict: :confirmed}
      assert {:error, reasons} = FindingSkeptic.promote(f)
      assert Enum.any?(reasons, &(&1 =~ "missing independent validator"))
    end

    test "completed confirmed with validator_id + poc promotes to status :confirmed" do
      assert {:ok, promoted} = FindingSkeptic.promote(@independent)
      assert promoted.status == :confirmed
      assert FindingSkeptic.independent?(promoted)
    end

    test "missing receipt even with validator errors include missing receipt" do
      f = %{
        validation_verdict: :confirmed,
        validation_status: :completed,
        validator_id: "agent-val-1"
      }

      assert {:error, reasons} = FindingSkeptic.promote(f)
      assert Enum.any?(reasons, &(&1 =~ "missing receipt"))
    end

    test "collects every missing piece" do
      assert {:error, reasons} = FindingSkeptic.promote(%{})
      assert "missing independent validator (spawn security_validation)" in reasons
      assert "validation did not confirm" in reasons
      assert "missing receipt (poc, evidence_path, or evidence_id)" in reasons
    end

    test "rejected verdict does not promote" do
      f = Map.put(@independent, :validation_verdict, :rejected)
      assert {:error, reasons} = FindingSkeptic.promote(f)
      assert "validation did not confirm" in reasons
    end

    test "evidence_path or evidence_id is a receipt" do
      base = Map.put(@independent, :poc, "")

      assert {:ok, _} =
               FindingSkeptic.promote(Map.put(base, :evidence_path, "/tmp/req.txt"))

      assert {:ok, _} =
               FindingSkeptic.promote(Map.put(base, :evidence_id, "ev-abc123def456"))
    end

    test "atomizes status on string-key findings" do
      f = %{
        "validation_verdict" => "confirmed",
        "validation_status" => "completed",
        "validator_id" => "agent-val-1",
        "poc" => "id=1 OR 1=1",
        "title" => "SQLi"
      }

      assert {:ok, promoted} = FindingSkeptic.promote(f)
      assert promoted.status == :confirmed
      assert promoted["title"] == "SQLi"
    end
  end

  describe "required?/1" do
    test "vulnerability-class findings require a skeptic" do
      assert FindingSkeptic.required?(%{vuln_class: :sqli})
    end

    test "info findings do not" do
      refute FindingSkeptic.required?(%{category: :info})
    end

    test "recon and finding notes do not require a skeptic" do
      refute FindingSkeptic.required?(%{category: :recon})
      refute FindingSkeptic.required?(%{category: :finding})
      refute FindingSkeptic.required?(:info)
      refute FindingSkeptic.required?(:recon)
      refute FindingSkeptic.required?(:finding)
    end

    test "category :vulnerability requires a skeptic" do
      assert FindingSkeptic.required?(%{category: :vulnerability})
      assert FindingSkeptic.required?(:vulnerability)
    end

    test "string keys work" do
      assert FindingSkeptic.required?(%{"vuln_class" => "sqli"})
      refute FindingSkeptic.required?(%{"category" => "info"})
    end
  end

  describe "spawn_spec/1" do
    test "profile is security_validation and prompt says independently" do
      spec = FindingSkeptic.spawn_spec(%{vuln_class: :sqli, target: "app.example.com"})

      assert spec.profile == "security_validation"
      assert spec.name =~ "validate-"
      assert spec.name =~ "sqli"
      assert spec.prompt =~ "independently"
      assert spec.prompt =~ "do not trust the parent conclusion"
      assert spec.success_criteria =~ "independent reproduction"
    end

    test "string keys work" do
      spec =
        FindingSkeptic.spawn_spec(%{"vuln_class" => "xss", "target" => "https://app.example.com"})

      assert spec.profile == "security_validation"
      assert spec.name =~ "validate-"
      assert spec.prompt =~ "independently"
    end
  end
end
