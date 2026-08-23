defmodule OptimalSystemAgent.Security.AttackTaxonomyTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.AttackTaxonomy

  test "lookup by id" do
    t = AttackTaxonomy.lookup("T1190")
    assert t.name =~ "Public-Facing"
    assert t.tactic == :initial_access
  end

  test "tag maps sqli and rce onto initial access / execution techniques" do
    assert %{technique_id: "T1190"} = AttackTaxonomy.tag(:sqli)
    assert %{technique_id: "T1190"} = AttackTaxonomy.tag(%{vuln_class: :rce})
    assert is_nil(AttackTaxonomy.tag(:not_a_class))
  end

  test "coverage_report splits tried vs untried" do
    report = AttackTaxonomy.coverage_report(["T1190", "T1059"])
    assert "T1190" in report.tried
    assert "T1486" in report.untried
    assert :initial_access in report.tactics_covered
    assert :impact in report.tactics_missing
  end

  test "navigator_layer has expected keys" do
    layer = AttackTaxonomy.navigator_layer(["T1190", "NOPE"])
    assert layer["name"]
    assert layer["versions"]
    assert [%{"techniqueID" => "T1190", "score" => 1}] = layer["techniques"]
  end

  test "by_tactic and all are non-empty" do
    assert length(AttackTaxonomy.all()) >= 25
    assert AttackTaxonomy.by_tactic(:credential_access) != []
  end
end
