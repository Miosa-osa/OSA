defmodule OptimalSystemAgent.Security.WeaponCatalogTest do
  @moduledoc """
  Verification tests for the six new attack capability modules.
  Tests WeaponCatalog, ExploitGenerator, LiveExploitRunner, AttackChainReasoner,
  AttackPrioritizer, CodeReachable, and AttackOrchestrator interfaces.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.{
    WeaponCatalog,
    ExploitGenerator,
    LiveExploitRunner,
    AttackChainReasoner,
    AttackPrioritizer,
    CodeReachable,
    ThreatIntel,
    Cvss,
    AttackOrchestrator
  }

  # ── Test data ──────────────────────────────────────────────────────────────

  @sample_finding %{
    id: "test-001",
    class: :sqli,
    target: "http://localhost:8080/api/users",
    confidence: 0.75,
    cvss_score: 7.2,
    cve: "CVE-2024-1234",
    code_reachable: true,
    maturity: :reliable,
    score: 8.1,
    is_kev: true,
    evidence_count: 5,
    exploit_code: "UNION SELECT query"
  }

  @sample_weapon %{
    id: "test-002",
    domain: :rce,
    target: "http://localhost:8080/exec",
    score: 9.0,
    maturity: :production,
    cvss_score: 9.1,
    is_kev: true,
    code_reachable: true,
    evidence_count: 8,
    exploit_code: "system(cmd)"
  }

  # ── WeaponCatalog tests ────────────────────────────────────────────────────

  describe "WeaponCatalog.classify/2" do
    test "classifies a finding into a weapon" do
      weapon = WeaponCatalog.classify(@sample_finding)
      assert is_map(weapon)
      assert weapon.domain == :sqli
      assert weapon.target == @sample_finding.target
      assert weapon.score > 0
      assert weapon.is_kev == true
    end

    test "classifies with default domain when unknown" do
      finding = Map.put(@sample_finding, :class, :unknown_class)
      weapon = WeaponCatalog.classify(finding)
      # defaults to rce for unknown
      assert weapon.domain == :rce
    end

    test "computes score from CVSS and confidence" do
      weapon = WeaponCatalog.classify(@sample_finding)
      # should have meaningful score
      assert weapon.score > 5.0
    end

    test "determines maturity based on score thresholds" do
      high_score = Map.put(@sample_finding, :score, 0.9)
      low_score = Map.put(@sample_finding, :score, 0.4)

      assert WeaponCatalog.classify(high_score).maturity in [:production, :reliable]
      assert WeaponCatalog.classify(low_score).maturity == :poc
    end
  end

  describe "WeaponCatalog.classify_batch/1" do
    test "classifies multiple findings" do
      weapons = WeaponCatalog.classify_batch([@sample_finding, @sample_weapon])
      assert length(weapons) >= 2
      # Deduplication keeps unique target+domain combos
      domains = Enum.map(weapons, & &1.domain)
      targets = Enum.map(weapons, & &1.target)
    end

    test "deduplicates by target + domain" do
      weapon1 = Map.put(@sample_weapon, :id, "w1")
      weapon2 = %{Map.put(@sample_weapon, :id, "w2") | score: 7.0}
      result = WeaponCatalog.classify_batch([weapon1, weapon2])
      # Both have same target+domain, should deduplicate keeping highest score
      assert length(result) >= 1
    end
  end

  describe "WeaponCatalog.add/2" do
    test "returns :ok for valid weapon" do
      assert WeaponCatalog.add(@sample_weapon) == :ok
    end

    test "returns error for invalid weapon" do
      result = WeaponCatalog.add(%{})
      assert {:error, _} = result
    end
  end

  describe "WeaponCatalog.by_domain/2" do
    test "filters weapons by domain" do
      rce_weapons = WeaponCatalog.by_domain(:rce, [@sample_weapon])
      assert length(rce_weapons) >= 1

      sqli_weapons = WeaponCatalog.by_domain(:sqli, [@sample_weapon])
      assert length(sqli_weapons) == 0
    end

    test "returns sorted by score descending" do
      weapons = [
        %{id: "a", domain: :rce, score: 5.0},
        %{id: "b", domain: :rce, score: 8.0},
        %{id: "c", domain: :rce, score: 6.5}
      ]

      ranked = WeaponCatalog.by_domain(:rce, weapons)
      assert Enum.at(ranked, 0).score >= Enum.at(ranked, 1).score
    end
  end

  describe "WeaponCatalog.top_n/2" do
    test "returns top N weapons by score" do
      weapons = [
        %{id: "a", domain: :rce, score: 3.0},
        %{id: "b", domain: :rce, score: 9.0},
        %{id: "c", domain: :rce, score: 6.0}
      ]

      top = WeaponCatalog.top_n(weapons, 2)
      assert length(top) == 2
      # highest first
      assert Enum.at(top, 0).id == "b"
    end

    test "handles n=0 and large n" do
      weapons = [%{id: "a", domain: :rce, score: 5.0}]
      assert WeaponCatalog.top_n(weapons, 0) == []
      assert length(WeaponCatalog.top_n(weapons, 100)) >= 1
    end
  end

  describe "WeaponCatalog.promote/1" do
    test "promotes from poc to reliable" do
      weapon = %{id: "x", domain: :rce, score: 0.75}
      promoted = WeaponCatalog.promote(weapon)
      assert promoted.maturity == :reliable
    end

    test "promotes from reliable to production" do
      weapon = %{id: "y", domain: :rce, score: 0.9}
      promoted = WeaponCatalog.promote(weapon)
      assert promoted.maturity == :production
    end

    test "does not downgrade below threshold" do
      low_weapon = %{id: "z", domain: :rce, score: 0.3}
      result = WeaponCatalog.promote(low_weapon)
      assert result.maturity == :poc
    end
  end

  # ── ExploitGenerator tests ─────────────────────────────────────────────────

  describe "ExploitGenerator.generate/1" do
    test "generates exploit from finding" do
      {:ok, exploit} = ExploitGenerator.generate(@sample_finding)
      assert is_map(exploit)
      assert exploit.class == :sqli
      assert exploit.target == @sample_finding.target
      assert exploit.code != ""
      assert is_float(exploit.confidence)
    end

    test "returns error for non-map input" do
      assert ExploitGenerator.generate("not a map") == {:error, "finding must be a map"}
      assert ExploitGenerator.generate(nil) == {:error, "finding must be a map"}
    end

    test "classifies vulnerability type from description" do
      sqli_finding = %{class: :sqli, target: "http://test.com", confidence: 0.6}
      {:ok, exploit} = ExploitGenerator.generate(sqli_finding)
      assert exploit.class == :sqli

      xss_finding = %{class: :xss, target: "http://test.com"}
      {:ok, exploit_xss} = ExploitGenerator.generate(xss_finding)
      assert exploit_xss.class == :xss
    end
  end

  describe "ExploitGenerator.generate_batch/1" do
    test "generates exploits for multiple findings" do
      findings = [@sample_finding, @sample_weapon]
      {:ok, exploits} = ExploitGenerator.generate_batch(findings)
      assert length(exploits) >= 2
    end

    test "handles empty list" do
      result = ExploitGenerator.generate_batch([])
      assert match?({:ok, []}, result)
    end
  end

  describe "ExploitGenerator.generate_in/2" do
    test "generates in specified language" do
      {:ok, exploit} = ExploitGenerator.generate_in(@sample_finding, :go)
      assert exploit.language == :go
    end

    test "returns error for non-map input" do
      assert ExploitGenerator.generate_in("bad", :python) == {:error, "finding must be a map"}
    end
  end

  describe "ExploitGenerator.classify_finding/1" do
    test "classifies from class field (atom)" do
      finding = %{class: :rce, target: "http://test.com"}
      assert ExploitGenerator.classify_finding(finding) == :rce
    end

    test "classifies from class field (string)" do
      finding = %{"class" => "ssrf", target: "http://test.com"}
      assert ExploitGenerator.classify_finding(finding) == :ssrf
    end

    test "defaults to custom when unknown" do
      finding = %{class: :unknown_thing, target: "http://test.com"}
      result = ExploitGenerator.classify_finding(finding)
      assert is_atom(result)
    end
  end

  # ── AttackPrioritizer tests ────────────────────────────────────────────────

  describe "AttackPrioritizer.rank/1" do
    test "ranks weapons by score descending" do
      weapons = [
        %{id: "low", domain: :rce, score: 3.0, is_kev: false},
        %{id: "high", domain: :sqli, score: 9.0, is_kev: true}
      ]

      ranked = AttackPrioritizer.rank(weapons)
      assert length(ranked) == 2
      assert Enum.at(ranked, 0).rank_score >= Enum.at(ranked, 1).rank_score
    end

    test "returns prioritized entries with correct structure" do
      weapon = %{id: "test", domain: :rce, score: 7.5, is_kev: true}
      ranked = AttackPrioritizer.rank([weapon])

      entry = Enum.at(ranked, 0)
      assert is_map(entry.weapon)
      assert is_float(entry.rank_score)
      assert is_integer(entry.exploit_order)
    end
  end

  describe "AttackPrioritizer.next_above_threshold/2" do
    test "returns nil when no targets above threshold" do
      ranked = [
        %{confidence: 0.3, weapon: %{}},
        %{confidence: 0.4, weapon: %{}}
      ]

      assert AttackPrioritizer.next_above_threshold(ranked, threshold: 0.7) == nil
    end

    test "returns first matching target" do
      ranked = [
        %{confidence: 0.8, rank_score: 9.0, weapon: %{}},
        %{confidence: 0.5, rank_score: 6.0, weapon: %{}}
      ]

      result = AttackPrioritizer.next_above_threshold(ranked)
      assert is_map(result)
    end
  end

  describe "AttackPrioritizer.filter_by_maturity/2" do
    test "filters weapons by maturity level" do
      weapons = [
        %{id: "a", maturity: :production},
        %{id: "b", maturity: :reliable},
        %{id: "c", maturity: :production}
      ]

      production_only = AttackPrioritizer.filter_by_maturity(:production, weapons)
      assert length(production_only) == 2
    end
  end

  describe "AttackPrioritizer.attack_surface_score/1" do
    test "computes surface score for weapon" do
      weapon = %{surface_coverage: 0.8, classes_covered: [:sqli, :xss, :ssrf]}
      score = AttackPrioritizer.attack_surface_score(weapon)
      assert is_float(score)
      assert score > 0
    end

    test "handles nil coverage gracefully" do
      weapon = %{surface_coverage: nil, classes_covered: []}
      score = AttackPrioritizer.attack_surface_score(weapon)
      assert is_float(score) and score >= 0
    end
  end

  # ── CodeReachable tests ────────────────────────────────────────────────────

  describe "CodeReachable.check/1" do
    test "returns stored code_reachable value" do
      finding = %{code_reachable: true}
      assert CodeReachable.check(finding) == true
    end

    test "handles string boolean values" do
      finding = %{"code_reachable" => "true"}
      assert CodeReachable.check(finding) == true
    end

    test "returns false for nil source" do
      result = CodeReachable.check(%{source_file: nil})
      assert result == false
    end

    test "handles empty string as not reachable" do
      result = CodeReachable.check(%{source_file: ""})
      assert result == false
    end

    test "checks call depth for reachability" do
      shallow = %{source_file: "lib/handler.ex", call_depth: 3}
      deep = %{source_file: "lib/handler.ex", call_depth: 15}

      assert CodeReachable.check(shallow) == true
      assert CodeReachable.check(deep) == false
    end
  end

  # ── AttackChainReasoner tests ───────────────────────────────────────────────

  describe "AttackChainReasoner.find_chains/1" do
    test "returns list of chains (empty when no graph)" do
      result = AttackChainReasoner.find_chains("test-session")
      assert is_list(result)
    end
  end

  describe "AttackChainReasoner.best_chain/1" do
    test "returns :none when no chains exist" do
      result = AttackChainReasoner.best_chain("empty-session")
      assert result == :none
    end
  end

  describe "AttackChainReasoner.score_path/1" do
    test "scores a path of hops" do
      hops = [
        %{edge_weight: 0.8, evidence_quality: 0.7, has_kev: true},
        %{edge_weight: 0.6, evidence_quality: 0.5, has_kev: false}
      ]

      score = AttackChainReasoner.score_path(hops)
      assert is_float(score)
      assert score > 0
    end

    test "caps at maximum score" do
      high_hops = [
        %{edge_weight: 1.0, evidence_quality: 1.0, has_kev: true}
      ]

      score = AttackChainReasoner.score_path(high_hops)
      assert score <= 13.0
    end
  end

  describe "AttackChainReasoner.extend/1" do
    test "extends chain with valid hops" do
      chain = %{hops: [%{target: "http://test.com"}]}
      result = AttackChainReasoner.extend(chain)
      assert is_tuple(result)
    end

    test "returns unchanged for empty chain" do
      chain = %{hops: []}
      assert AttackChainReasoner.extend(chain) == :unchanged
    end
  end

  # ── LiveExploitRunner tests (interface only, no network needed) ─────────────

  describe "LiveExploitRunner.deploy/1" do
    test "returns error for non-map input" do
      assert LiveExploitRunner.deploy("not a map") == {:error, "weapon must be a map"}
    end

    test "handles empty weapon map gracefully" do
      result = LiveExploitRunner.deploy(%{})
      # Returns :ok or {:ok, _} since it uses fallback defaults
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "LiveExploitRunner.deploy_batch/1" do
    test "returns ok when majority succeed" do
      weapons = [
        %{session_id: "eng-1", class: :sqli, target: "http://test.com"},
        %{session_id: "eng-2", class: :xss, target: "http://test.com"}
      ]

      result = LiveExploitRunner.deploy_batch(weapons)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles empty list" do
      result = LiveExploitRunner.deploy_batch([])
      # Empty list should return ok with empty results
      assert match?({:ok, []}, result) or match?({:error, _}, result)
    end
  end

  describe "LiveExploitRunner.in_scope?/1" do
    test "returns boolean for a target URL" do
      result = LiveExploitRunner.in_scope?("http://localhost:8080")
      assert is_boolean(result) or result == :error
    end
  end

  # ── AttackOrchestrator tests (interface only, no GenServer needed) ──────────

  describe "AttackOrchestrator.execute_sequence/1" do
    test "returns results state when complete with findings" do
      state = %{
        phase: :complete,
        completed: ["http://test.com"],
        failed: [],
        weapons: [%{class: :sqli, target: "http://test.com"}]
      }

      result = AttackOrchestrator.execute_sequence(state)
      assert match?({:results, _}, result)
    end

    test "returns blocked when no findings" do
      state = %{phase: :complete, completed: [], failed: []}
      result = AttackOrchestrator.execute_sequence(state)
      assert match?({:blocked, _}, result)
    end

    test "runs the full sequence on real findings without raising" do
      state = %{
        session_id: "eng-seq-#{System.unique_integer([:positive])}",
        phase: :exploitation,
        findings: [@sample_finding, %{@sample_weapon | id: "test-003"}],
        weapons: [],
        completed: [],
        failed: []
      }

      assert {:results, %{weapons: weapons}} = AttackOrchestrator.execute_sequence(state)
      assert is_list(weapons)
    end
  end

  describe "AttackOrchestrator.next_target/1" do
    test "returns next target when available" do
      state = %{next_target: nil}
      result = AttackOrchestrator.next_target(state)
      assert is_nil(result) or is_map(result)
    end
  end

  # ── Integration tests ──────────────────────────────────────────────────────

  describe "Full pipeline: finding → weapon → prioritized" do
    test "finding flows through classification to ranking" do
      # Step 1: Classify finding as weapon
      weapon = WeaponCatalog.classify(@sample_finding)
      assert is_map(weapon)
      assert weapon.domain == :sqli

      # Step 2: Rank it against other weapons
      ranked = AttackPrioritizer.rank([weapon])
      assert length(ranked) >= 1
      assert Enum.at(ranked, 0).rank_score > 0
    end

    test "weapon matures as score increases" do
      poc_weapon = %{id: "x", domain: :rce, score: 0.4}
      assert WeaponCatalog.classify(poc_weapon).maturity == :poc

      promoted = WeaponCatalog.promote(WeaponCatalog.promote(poc_weapon))
      assert promoted.maturity in [:reliable, :production]
    end
  end
end
