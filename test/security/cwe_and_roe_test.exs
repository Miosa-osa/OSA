defmodule OptimalSystemAgent.Security.CweAndRoeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.CweCatalog
  alias OptimalSystemAgent.Security.RoeGuard
  alias OptimalSystemAgent.Security.Cvss

  describe "CweCatalog" do
    test "maps the whitebox analyzer's classes to a CWE, OWASP category, and a scorable CVSS vector" do
      for class <- [
            :sqli,
            :rce,
            :ssrf,
            :idor,
            :xss,
            :lfi,
            :path_traversal,
            :xxe,
            :ssti,
            :deserialization
          ] do
        entry = CweCatalog.lookup(class)
        assert %{cwe: "CWE-" <> _, owasp: "A" <> _, typical_cvss: vector} = entry

        assert {:ok, _} = Cvss.score(vector),
               "#{class}'s typical vector must be a valid CVSS string"
      end
    end

    test "an unmapped class returns nil rather than a fabricated mapping" do
      assert CweCatalog.lookup(:not_a_real_class) == nil
      assert CweCatalog.cwe(:not_a_real_class) == nil
    end

    test "known accessors" do
      assert CweCatalog.cwe(:sqli) == "CWE-89"
      assert CweCatalog.owasp(:ssrf) =~ "A10"
    end
  end

  describe "RoeGuard scope matching" do
    setup do
      %{
        contract: %{
          targets: ["10.0.0.0/24", "app.example.com", "*.staging.example.com"],
          forbidden: [:destructive],
          max_blast: :cred_access
        }
      }
    end

    test "CIDR, exact host, and glob domain all match; others do not", %{contract: c} do
      assert RoeGuard.in_scope?(c, "10.0.0.42")
      refute RoeGuard.in_scope?(c, "10.0.1.42")
      assert RoeGuard.in_scope?(c, "app.example.com")
      assert RoeGuard.in_scope?(c, "web.staging.example.com")
      refute RoeGuard.in_scope?(c, "evil.com")
      # glob is single-label, not a wildcard-everything
      refute RoeGuard.in_scope?(c, "deep.web.staging.example.com")
    end
  end

  describe "RoeGuard.classify/1 blast radius" do
    test "verbs map to the right ladder rung, unknown is access not recon" do
      assert RoeGuard.classify("nmap -sV 10.0.0.5") == :recon
      assert RoeGuard.classify("sqlmap -u http://x --batch") == :access
      assert RoeGuard.classify("secretsdump.py user@host") == :cred_access
      assert RoeGuard.classify("crackmapexec smb 10.0.0.0/24") == :lateral
      assert RoeGuard.classify("crontab -e") == :persistence
      assert RoeGuard.classify("mkfs.ext4 /dev/sda") == :destructive
      assert RoeGuard.classify("some-novel-tool --flag") == :access
    end
  end

  describe "RoeGuard.check/2 verdicts" do
    setup do
      %{c: %{targets: ["10.0.0.0/24"], forbidden: [:destructive], max_blast: :cred_access}}
    end

    test "in-scope recon is allowed", %{c: c} do
      assert {:allow, _} = RoeGuard.check(c, %{blast: :recon, target: "10.0.0.5"})
    end

    test "forbidden class is hard-blocked", %{c: c} do
      assert {:block, reason} = RoeGuard.check(c, %{blast: :destructive, target: "10.0.0.5"})
      assert reason =~ "forbidden"
    end

    test "blast above max needs human authorization", %{c: c} do
      assert {:needs_authorization, _} =
               RoeGuard.check(c, %{blast: :persistence, target: "10.0.0.5"})
    end

    test "out-of-scope target is blocked regardless of blast", %{c: c} do
      assert {:block, reason} = RoeGuard.check(c, %{blast: :recon, target: "8.8.8.8"})
      assert reason =~ "scope"
    end

    test "no contract fails safe: recon allowed, anything else needs authorization" do
      assert {:allow, _} = RoeGuard.check(nil, %{blast: :recon})
      assert {:needs_authorization, _} = RoeGuard.check(nil, %{blast: :access})
    end

    test "outside the engagement window is blocked" do
      c = %{
        targets: ["10.0.0.0/24"],
        window: {~U[2020-01-01 00:00:00Z], ~U[2020-01-02 00:00:00Z]}
      }

      assert {:block, reason} =
               RoeGuard.check(c, %{
                 blast: :recon,
                 target: "10.0.0.5",
                 now: ~U[2026-01-01 00:00:00Z]
               })

      assert reason =~ "window"
    end
  end
end
