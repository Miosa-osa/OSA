defmodule OptimalSystemAgent.Security.ValidationResultTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.{FindingSkeptic, ValidationResult}

  @confirmed %{
    verdict: :confirmed,
    confidence: :medium,
    affected_asset: "https://app.example.com/search",
    weakness_class: "sqli",
    claimed_impact: "read other users' rows",
    reproduction: "GET /search?q=' OR 1=1-- and observe dump",
    evidence_refs: ["http://app.example.com/search?q=%27+OR+1%3D1"],
    limitations: "",
    validator_id: "agent-val-1"
  }

  @rejected %{
    verdict: :rejected,
    affected_asset: "https://app.example.com/profile",
    weakness_class: "xss",
    limitations: "payload is HTML-encoded; no script execution"
  }

  describe "parse/1" do
    test "parse confirmed with evidence + reproduction + medium -> ok" do
      assert {:ok, result} = ValidationResult.parse(@confirmed)
      assert result.verdict == :confirmed
      assert result.status == :completed
      assert result.confidence == :medium
      assert result.affected_asset == "https://app.example.com/search"
      assert result.weakness_class == "sqli"
      assert result.reproduction =~ "OR 1=1"
      assert result.evidence_refs == ["http://app.example.com/search?q=%27+OR+1%3D1"]
      assert result.validator_id == "agent-val-1"
    end

    test "parse confirmed without evidence -> error includes evidence" do
      input = Map.put(@confirmed, :evidence_refs, [])
      assert {:error, reasons} = ValidationResult.parse(input)
      assert Enum.any?(reasons, &(&1 =~ "evidence"))
    end

    test "parse rejected with limitations -> ok" do
      assert {:ok, result} = ValidationResult.parse(@rejected)
      assert result.verdict == :rejected
      assert result.status == :completed
      assert result.limitations =~ "HTML-encoded"
    end

    test "string keys work" do
      input = %{
        "verdict" => "confirmed",
        "confidence" => "high",
        "affected_asset" => "https://app.example.com/search",
        "weakness_class" => "sqli",
        "claimed_impact" => "dump",
        "reproduction" => "repeat the GET with a quote",
        "evidence_refs" => ["receipt-abc"],
        "limitations" => "",
        "validator_id" => "agent-val-9"
      }

      assert {:ok, result} = ValidationResult.parse(input)
      assert result.verdict == :confirmed
      assert result.confidence == :high
      assert result.status == :completed
      assert result.evidence_refs == ["receipt-abc"]
    end

    test "collects every missing piece" do
      assert {:error, reasons} = ValidationResult.parse(%{})
      assert Enum.any?(reasons, &(&1 =~ "verdict"))
      assert Enum.any?(reasons, &(&1 =~ "affected_asset"))
      assert Enum.any?(reasons, &(&1 =~ "weakness_class"))
    end

    test "confirmed without reproduction errors include reproduction" do
      input = Map.put(@confirmed, :reproduction, "")
      assert {:error, reasons} = ValidationResult.parse(input)
      assert Enum.any?(reasons, &(&1 =~ "reproduction"))
    end

    test "confirmed with low confidence is rejected" do
      input = Map.put(@confirmed, :confidence, :low)
      assert {:error, reasons} = ValidationResult.parse(input)
      assert Enum.any?(reasons, &(&1 =~ "confidence"))
    end

    test "rejected without evidence requires limitations" do
      input = %{
        verdict: :rejected,
        affected_asset: "https://app.example.com",
        weakness_class: "xss",
        evidence_refs: [],
        limitations: ""
      }

      assert {:error, reasons} = ValidationResult.parse(input)
      assert Enum.any?(reasons, &(&1 =~ "limitations"))
    end

    test "inconclusive with evidence may omit limitations" do
      input = %{
        verdict: :inconclusive,
        affected_asset: "https://app.example.com/api",
        weakness_class: "ssrf",
        evidence_refs: ["/tmp/ssrf-500.txt"],
        limitations: ""
      }

      assert {:ok, result} = ValidationResult.parse(input)
      assert result.verdict == :inconclusive
      assert result.status == :completed
    end

    test "status is completed even when the child sent another status" do
      input = Map.put(@confirmed, :status, :failed)
      assert {:ok, result} = ValidationResult.parse(input)
      assert result.status == :completed
    end

    test "reproduction_steps list is accepted as reproduction" do
      input =
        @confirmed
        |> Map.delete(:reproduction)
        |> Map.put(:reproduction_steps, ["open /search", "inject quote"])

      assert {:ok, result} = ValidationResult.parse(input)
      assert result.reproduction =~ "open /search"
      assert result.reproduction =~ "inject quote"
    end
  end

  describe "to_finding/1" do
    test "to_finding has validation_verdict :confirmed and poc" do
      assert {:ok, result} = ValidationResult.parse(@confirmed)
      finding = ValidationResult.to_finding(result)

      assert finding.validation_verdict == :confirmed
      assert finding.validation_status == :completed
      assert finding.validator_id == "agent-val-1"
      assert is_binary(finding.poc) and finding.poc != ""
      assert finding.vuln_class == :sqli
    end

    test "poc falls back to reproduction when evidence_refs is empty on a parsed rejected result" do
      input = %{
        verdict: :rejected,
        affected_asset: "https://app.example.com",
        weakness_class: "xss",
        reproduction: "tried alert(1); encoded",
        limitations: "encoded",
        validator_id: "agent-val-2"
      }

      assert {:ok, result} = ValidationResult.parse(input)
      finding = ValidationResult.to_finding(result)
      assert finding.validation_verdict == :rejected
      assert finding.poc =~ "alert(1)"
    end
  end

  describe "promote/1" do
    test "parsed confirmed result feeds FindingSkeptic.promote" do
      assert {:ok, finding} = ValidationResult.promote(@confirmed)
      assert finding.status == :confirmed
      assert FindingSkeptic.independent?(finding)
    end

    test "rejected does not promote" do
      input = Map.merge(@rejected, %{validator_id: "agent-val-1", evidence_refs: ["receipt"]})
      assert {:error, reasons} = ValidationResult.promote(input)
      assert Enum.any?(reasons, &(&1 =~ "confirm" or &1 =~ "verdict" or &1 =~ "rejected"))
    end
  end

  describe "schema_prompt/0" do
    test "schema_prompt mentions untrusted and independently" do
      prompt = ValidationResult.schema_prompt()
      assert is_binary(prompt)
      assert prompt =~ "untrusted"
      assert prompt =~ "independently"
    end
  end

  describe "agent file" do
    test "agent file exists and contains Do not trust" do
      path = Path.join([File.cwd!(), "priv", "agents", "security-validation.md"])
      assert File.exists?(path)
      body = File.read!(path)
      assert body =~ "Do not trust"
    end
  end
end
