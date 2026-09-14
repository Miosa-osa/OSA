defmodule OptimalSystemAgent.Security.ThreatIntelTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.ThreatIntel

  test "bundled KEV contains Log4Shell" do
    assert ThreatIntel.known_exploited?("CVE-2021-44228")
    assert {:ok, entry} = ThreatIntel.lookup("cve-2021-44228")
    assert entry["shortName"] =~ "Log4"
  end

  test "unknown CVE is not found" do
    refute ThreatIntel.known_exploited?("CVE-1999-0001")
    assert ThreatIntel.lookup("CVE-1999-0001") == :not_found
  end

  test "enrich marks KEV findings and leaves others false" do
    hot = ThreatIntel.enrich(%{cve: "CVE-2021-44228", cvss_score: 10.0})
    assert hot.kev == true
    assert is_map(hot.kev_entry)

    cold = ThreatIntel.enrich(%{cve: "CVE-1999-0001", cvss_score: 5.0})
    assert cold.kev == false
    assert cold.kev_entry == nil
  end

  test "priority adds 1.5 for KEV and 3*epss (EPSS-weighted formula)" do
    p =
      ThreatIntel.priority(%{
        cve: "CVE-2021-44228",
        cvss_score: 10.0,
        epss: 0.5
      })

    # KEV ransomware entry: 10.0 base + 2.5 KEV/ransomware + 1.5 ransomware bonus + 1.5 EPSS
    assert_in_delta p, 15.0, 0.01
  end

  test "load_feed merges a temp JSON overlay" do
    path = Path.join(System.tmp_dir!(), "osa-kev-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!([%{"cve" => "CVE-2099-0001", "shortName" => "fake"}]))

    try do
      assert :ok = ThreatIntel.load_feed(path)
      assert ThreatIntel.known_exploited?("CVE-2099-0001")
    after
      File.rm(path)
    end
  end
end
