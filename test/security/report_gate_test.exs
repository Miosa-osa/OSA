defmodule OptimalSystemAgent.Security.ReportGateTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.ReportGate

  @eligible %{
    vuln_class: :sqli,
    cvss_vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H",
    poc: "id=1 OR 1=1",
    reasoning: "concatenated SQL"
  }

  test "enriches an eligible finding with score, CWE, and OWASP" do
    assert {:ok, f} = ReportGate.evaluate(@eligible)
    assert f.cvss_score == 9.8
    assert f.severity == :critical
    assert f.cwe == "CWE-89"
    assert f.owasp =~ "Injection"
    assert ReportGate.eligible?(@eligible)
  end

  test "accepts string keys" do
    raw = %{
      "vuln_class" => "sqli",
      "cvss_vector" => "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H",
      "evidence_path" => "/tmp/req.txt"
    }

    assert {:ok, f} = ReportGate.evaluate(raw)
    assert f.cwe == "CWE-89"
  end

  test "rejects missing vector, CWE, and evidence with all reasons" do
    assert {:error, reasons} = ReportGate.evaluate(%{vuln_class: :not_a_real_class})
    assert Enum.any?(reasons, &(&1 =~ "CVSS"))
    assert Enum.any?(reasons, &(&1 =~ "CWE"))
    assert Enum.any?(reasons, &(&1 =~ "evidence"))
    refute ReportGate.eligible?(%{})
  end

  test "confirmed status without a receipt is not evidence" do
    f = Map.merge(@eligible, %{poc: "", status: :confirmed})
    assert {:error, reasons} = ReportGate.evaluate(f)
    assert Enum.any?(reasons, &(&1 =~ "evidence"))
  end

  test "hashed evidence_id is a receipt" do
    f = Map.merge(@eligible, %{poc: "", evidence_id: "ev-abc123def456"})
    assert {:ok, _} = ReportGate.evaluate(f)
  end

  test "filter keeps only eligible findings" do
    kept = ReportGate.filter([@eligible, %{vuln_class: :xss}])
    assert length(kept) == 1
    assert hd(kept).cwe == "CWE-89"
  end
end
