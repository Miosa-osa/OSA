defmodule OptimalSystemAgent.Security.CvssTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.Cvss

  describe "score/1 against FIRST.org v3.1 reference vectors" do
    # These base scores are the canonical values published in the CVSS v3.1
    # specification and calculator; they pin the arithmetic (weights, the
    # scope-dependent impact/PR paths, and the integer roundup) exactly.
    test "network RCE, unchanged scope, full impact -> 9.8 critical" do
      assert {:ok, %{base_score: 9.8, severity: :critical}} =
               Cvss.score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    end

    test "changed scope pushes the same impact to the 10.0 ceiling" do
      assert {:ok, %{base_score: 10.0, severity: :critical}} =
               Cvss.score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H")
    end

    test "high complexity + user interaction, low confidentiality only -> 3.1 low" do
      assert {:ok, %{base_score: 3.1, severity: :low}} =
               Cvss.score("CVSS:3.1/AV:N/AC:H/PR:N/UI:R/S:U/C:L/I:N/A:N")
    end

    test "local privileged full-impact -> 7.8 high" do
      assert {:ok, %{base_score: 7.8, severity: :high}} =
               Cvss.score("CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H")
    end

    test "no impact -> 0.0 none" do
      assert {:ok, %{base_score: 0.0, severity: :none}} =
               Cvss.score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N")
    end
  end

  describe "parsing" do
    test "accepts a vector without the CVSS:3.1 prefix and is order-independent" do
      assert {:ok, %{base_score: 9.8}} =
               Cvss.score("C:H/A:H/AV:N/I:H/AC:L/S:U/PR:N/UI:N")
    end

    test "ignores trailing temporal/environmental metrics" do
      assert {:ok, %{base_score: 9.8}} =
               Cvss.score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H/E:P/RL:O")
    end

    test "round-trips a canonical vector string" do
      assert {:ok, %{vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}} =
               Cvss.score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    end
  end

  describe "a bad score is refused, never fabricated" do
    test "an incomplete vector reports the missing metric" do
      assert {:error, reason} = Cvss.score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H")
      assert reason =~ "A"
    end

    test "an invalid metric value is rejected" do
      assert {:error, _} = Cvss.score("CVSS:3.1/AV:Z/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    end

    test "garbage input is an error, not a zero score" do
      assert {:error, _} = Cvss.score("not a vector")
      assert {:error, _} = Cvss.score(nil)
    end
  end

  describe "severity/1 bands" do
    test "boundaries match the qualitative scale" do
      assert Cvss.severity(0.0) == :none
      assert Cvss.severity(0.1) == :low
      assert Cvss.severity(3.9) == :low
      assert Cvss.severity(4.0) == :medium
      assert Cvss.severity(6.9) == :medium
      assert Cvss.severity(7.0) == :high
      assert Cvss.severity(8.9) == :high
      assert Cvss.severity(9.0) == :critical
      assert Cvss.severity(10.0) == :critical
    end
  end
end
