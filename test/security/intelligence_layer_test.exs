defmodule OptimalSystemAgent.Security.StructuredNotesTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.StructuredNotes

  describe "validate/1 — credential category" do
    test "valid credential note with password" do
      :ok =
        StructuredNotes.validate(%{
          category: :credential,
          username: "root",
          target: "10.0.0.1",
          password: "toor"
        })
    end

    test "valid credential note with protocol instead of password" do
      :ok =
        StructuredNotes.validate(%{
          category: :credential,
          username: "admin",
          target: "10.0.0.2",
          protocol: "ssh"
        })
    end

    test "rejects credential without username" do
      {:error, reason} =
        StructuredNotes.validate(%{
          category: :credential,
          target: "10.0.0.1",
          password: "pass"
        })

      assert String.contains?(reason, "username")
    end

    test "rejects credential without target" do
      {:error, reason} =
        StructuredNotes.validate(%{
          category: :credential,
          username: "root",
          password: "pass"
        })

      assert String.contains?(reason, "target")
    end

    test "rejects credential without password or protocol" do
      {:error, reason} =
        StructuredNotes.validate(%{
          category: :credential,
          username: "root",
          target: "10.0.0.1"
        })

      assert String.contains?(reason, "password") or String.contains?(reason, "protocol")
    end
  end

  describe "validate/1 — vulnerability category" do
    test "valid vulnerability note with cve" do
      :ok =
        StructuredNotes.validate(%{
          category: :vulnerability,
          target: "https://example.com",
          cve: "CVE-2024-1234"
        })
    end

    test "valid vulnerability note with weaknesses instead of cve" do
      :ok =
        StructuredNotes.validate(%{
          category: :vulnerability,
          target: "10.0.0.1",
          weaknesses: [%{id: "CWE-89", description: "SQL injection"}]
        })
    end

    test "rejects vulnerability without target" do
      {:error, reason} =
        StructuredNotes.validate(%{
          category: :vulnerability,
          cve: "CVE-2024-1234"
        })

      assert String.contains?(reason, "target")
    end

    test "rejects vulnerability without cve or weaknesses" do
      {:error, reason} =
        StructuredNotes.validate(%{
          category: :vulnerability,
          target: "10.0.0.1"
        })

      assert String.contains?(reason, "cve") or String.contains?(reason, "weaknesses")
    end
  end

  describe "validate/1 — finding category" do
    test "valid finding with services" do
      :ok =
        StructuredNotes.validate(%{
          category: :finding,
          target: "10.0.0.1",
          services: [%{port: 22, product: "OpenSSH", version: "8.9"}]
        })
    end

    test "valid finding with port" do
      :ok =
        StructuredNotes.validate(%{
          category: :finding,
          target: "10.0.0.1",
          port: "80"
        })
    end

    test "rejects finding without target" do
      {:error, reason} =
        StructuredNotes.validate(%{
          category: :finding,
          services: [%{port: 22}]
        })

      assert String.contains?(reason, "target")
    end

    test "rejects finding without services/endpoints/technologies/port" do
      {:error, reason} =
        StructuredNotes.validate(%{
          category: :finding,
          target: "10.0.0.1"
        })

      assert String.contains?(reason, "services") or String.contains?(reason, "endpoints") or
               String.contains?(reason, "technologies") or String.contains?(reason, "port")
    end
  end

  describe "validate/1 — info category" do
    test "valid info note with no required fields" do
      :ok = StructuredNotes.validate(%{category: :info})
    end
  end

  describe "validate/1 — invalid category" do
    test "rejects unknown category" do
      {:error, reason} = StructuredNotes.validate(%{category: :unknown})
      assert String.contains?(reason, "Invalid category")
    end

    test "rejects missing category" do
      {:error, reason} = StructuredNotes.validate(%{target: "10.0.0.1"})
      assert String.contains?(reason, "category")
    end
  end

  describe "create/2" do
    test "creates a valid credential note" do
      {:ok, note} =
        StructuredNotes.create("creds_ssh", %{
          category: :credential,
          content: "SSH creds via hydra",
          username: "root",
          password: "toor",
          target: "10.0.0.1",
          protocol: "ssh"
        })

      assert note.key == "creds_ssh"
      assert note.category == :credential
      assert note.username == "root"
      assert note.target == "10.0.0.1"
    end

    test "rejects invalid note" do
      {:error, _reason} = StructuredNotes.create("bad", %{category: :credential})
    end
  end

  describe "extract_hosts/1" do
    test "extracts IPs from content" do
      note =
        StructuredNotes.build_note("test", %{
          category: :finding,
          content: "Found hosts 10.0.0.1 and 192.168.1.1",
          target: "10.0.0.1"
        })

      hosts = StructuredNotes.extract_hosts(note)
      assert "10.0.0.1" in hosts
      assert "192.168.1.1" in hosts
    end

    test "includes target and source from metadata" do
      note =
        StructuredNotes.build_note("test", %{
          category: :credential,
          content: "creds",
          target: "10.0.0.1",
          source: "10.0.0.2"
        })

      hosts = StructuredNotes.extract_hosts(note)
      assert "10.0.0.1" in hosts
      assert "10.0.0.2" in hosts
    end
  end
end

defmodule OptimalSystemAgent.Security.ShadowGraphTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.ShadowGraph
  alias OptimalSystemAgent.Security.StructuredNotes

  describe "new/0" do
    test "creates empty graph" do
      graph = ShadowGraph.new()
      assert graph.nodes == %{}
      assert graph.edges == []
    end
  end

  describe "update_from_notes/2" do
    setup do
      {:ok, cred_note} =
        StructuredNotes.create("creds_ssh", %{
          category: :credential,
          content: "SSH creds for 10.0.0.1",
          username: "root",
          password: "toor",
          target: "10.0.0.1",
          protocol: "ssh"
        })

      {:ok, finding_note} =
        StructuredNotes.create("open_ports", %{
          category: :finding,
          content: "Open ports on 10.0.0.1",
          target: "10.0.0.1",
          services: [%{port: 22, product: "OpenSSH", version: "8.9"}]
        })

      {:ok, vuln_note} =
        StructuredNotes.create("vuln_sqli", %{
          category: :vulnerability,
          content: "SQL injection on 10.0.0.1",
          target: "10.0.0.1",
          cve: "CVE-2024-1234"
        })

      {:ok, cred_note: cred_note, finding_note: finding_note, vuln_note: vuln_note}
    end

    test "adds host nodes from notes", %{cred_note: cred_note} do
      graph = ShadowGraph.new() |> ShadowGraph.update_from_notes([cred_note])
      hosts = ShadowGraph.hosts(graph)
      assert length(hosts) >= 1
      assert Enum.any?(hosts, &(&1.label == "10.0.0.1"))
    end

    test "adds service nodes from finding notes", %{finding_note: finding_note} do
      graph = ShadowGraph.new() |> ShadowGraph.update_from_notes([finding_note])
      services = ShadowGraph.nodes_of_type(graph, "service")
      assert length(services) >= 1
      assert Enum.any?(services, &String.contains?(&1.label, "22"))
    end

    test "adds credential nodes and AUTH_ACCESS edges", %{cred_note: cred_note} do
      graph = ShadowGraph.new() |> ShadowGraph.update_from_notes([cred_note])
      creds = ShadowGraph.nodes_of_type(graph, "credential")
      assert length(creds) >= 1

      auth_edges = ShadowGraph.edges_of_type(graph, :AUTH_ACCESS)
      assert length(auth_edges) >= 1
    end

    test "adds vulnerability nodes and HAS_VULNERABILITY edges", %{vuln_note: vuln_note} do
      graph = ShadowGraph.new() |> ShadowGraph.update_from_notes([vuln_note])
      vulns = ShadowGraph.nodes_of_type(graph, "vulnerability")
      assert length(vulns) >= 1

      vuln_edges = ShadowGraph.edges_of_type(graph, :HAS_VULNERABILITY)
      assert length(vuln_edges) >= 1
    end

    test "adds HAS_SERVICE edges from finding notes", %{finding_note: finding_note} do
      graph = ShadowGraph.new() |> ShadowGraph.update_from_notes([finding_note])
      service_edges = ShadowGraph.edges_of_type(graph, :HAS_SERVICE)
      assert length(service_edges) >= 1
    end
  end

  describe "strategic_insights/1" do
    test "detects unscanned hosts with credentials" do
      {:ok, cred_note} =
        StructuredNotes.create("creds_ssh", %{
          category: :credential,
          content: "SSH creds for 10.0.0.5",
          username: "root",
          password: "toor",
          target: "10.0.0.5",
          protocol: "ssh"
        })

      graph = ShadowGraph.new() |> ShadowGraph.update_from_notes([cred_note])
      insights = ShadowGraph.strategic_insights(graph)

      unscanned = Enum.find(insights, &String.contains?(&1, "haven't scanned"))
      assert unscanned != nil
      assert String.contains?(unscanned, "10.0.0.5")
    end

    test "detects services without vulnerabilities" do
      {:ok, finding_note} =
        StructuredNotes.create("open_ports", %{
          category: :finding,
          content: "Open ports on 10.0.0.1",
          target: "10.0.0.1",
          services: [%{port: 80, product: "nginx"}]
        })

      graph = ShadowGraph.new() |> ShadowGraph.update_from_notes([finding_note])
      insights = ShadowGraph.strategic_insights(graph)

      no_vulns = Enum.find(insights, &String.contains?(&1, "no vulnerabilities"))
      assert no_vulns != nil
    end

    test "detects confirmed vulnerabilities" do
      {:ok, vuln_note} =
        StructuredNotes.create("vuln_sqli", %{
          category: :vulnerability,
          content: "SQL injection on 10.0.0.1",
          target: "10.0.0.1",
          cve: "CVE-2024-1234"
        })

      graph = ShadowGraph.new() |> ShadowGraph.update_from_notes([vuln_note])
      insights = ShadowGraph.strategic_insights(graph)

      confirmed = Enum.find(insights, &String.contains?(&1, "confirmed vulnerability"))
      assert confirmed != nil
      assert String.contains?(confirmed, "CVE-2024-1234")
    end
  end
end

defmodule OptimalSystemAgent.Security.TaskDifficultyTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.TaskDifficultyAssessment

  describe "score_horizon/1" do
    test "0 steps remaining = 1.0 (certain)" do
      assert TaskDifficultyAssessment.score_horizon(0) == 1.0
    end

    test "20+ steps remaining = 0.0 (very uncertain)" do
      assert TaskDifficultyAssessment.score_horizon(20) == 0.0
      assert TaskDifficultyAssessment.score_horizon(30) == 0.0
    end

    test "10 steps = 0.5" do
      assert TaskDifficultyAssessment.score_horizon(10) == 0.5
    end
  end

  describe "score_confidence/1" do
    test "high confidence = high score" do
      assert TaskDifficultyAssessment.score_confidence(0.9) == 0.9
    end

    test "low confidence = low score" do
      assert TaskDifficultyAssessment.score_confidence(0.1) == 0.1
    end

    test "clamps to 0-1" do
      assert TaskDifficultyAssessment.score_confidence(1.5) == 1.0
      assert TaskDifficultyAssessment.score_confidence(-0.5) == 0.0
    end
  end

  describe "assess/1" do
    test "returns exploit when confidence is high and horizon is low" do
      {:ok, result} =
        TaskDifficultyAssessment.assess(%{
          steps_remaining: 2,
          evidence_confidence: 0.9,
          context_load: 0.3,
          historical_success_rate: 0.7,
          task_type: :exploitation
        })

      assert result.decision == :exploit
      assert result.confidence > 0.5
    end

    test "returns explore when confidence is low and horizon is high" do
      {:ok, result} =
        TaskDifficultyAssessment.assess(%{
          steps_remaining: 18,
          evidence_confidence: 0.2,
          context_load: 0.2,
          historical_success_rate: 0.3,
          task_type: :exploitation
        })

      assert result.decision == :explore
      assert result.confidence < 0.5
    end

    test "returns exploit when context load is high (finish before context runs out)" do
      {:ok, result} =
        TaskDifficultyAssessment.assess(%{
          steps_remaining: 10,
          evidence_confidence: 0.5,
          context_load: 0.95,
          historical_success_rate: 0.5,
          task_type: :exploitation
        })

      assert result.decision == :exploit
    end

    test "includes reasoning string" do
      {:ok, result} =
        TaskDifficultyAssessment.assess(%{
          steps_remaining: 5,
          evidence_confidence: 0.7,
          context_load: 0.4,
          historical_success_rate: 0.6
        })

      assert is_binary(result.reasoning)
      assert String.contains?(result.reasoning, "confidence")
    end

    test "includes scores breakdown" do
      {:ok, result} =
        TaskDifficultyAssessment.assess(%{
          steps_remaining: 5,
          evidence_confidence: 0.7,
          context_load: 0.4,
          historical_success_rate: 0.6
        })

      assert Map.has_key?(result.scores, :horizon)
      assert Map.has_key?(result.scores, :confidence)
      assert Map.has_key?(result.scores, :context_load)
      assert Map.has_key?(result.scores, :success_rate)
    end

    test "rejects invalid input" do
      {:error, _} = TaskDifficultyAssessment.assess("invalid")
    end
  end
end

defmodule OptimalSystemAgent.Security.VulnDeduplicationTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.VulnDeduplication

  describe "check_dependency/2" do
    test "same CVE + same package = duplicate" do
      candidate = %{
        id: "vuln-002",
        cve: "CVE-2024-1234",
        dependency_metadata: %{package_name: "lodash", package_ecosystem: "npm"}
      }

      existing = [
        %{
          id: "vuln-001",
          cve: "CVE-2024-1234",
          dependency_metadata: %{package_name: "lodash", package_ecosystem: "npm"}
        }
      ]

      {:ok, result} = VulnDeduplication.check_dependency(candidate, existing)
      assert result.is_duplicate == true
      assert result.duplicate_id == "vuln-001"
    end

    test "same CVE + different package = NOT duplicate" do
      candidate = %{
        id: "vuln-002",
        cve: "CVE-2024-1234",
        dependency_metadata: %{package_name: "express", package_ecosystem: "npm"}
      }

      existing = [
        %{
          id: "vuln-001",
          cve: "CVE-2024-1234",
          dependency_metadata: %{package_name: "lodash", package_ecosystem: "npm"}
        }
      ]

      result = VulnDeduplication.check_dependency(candidate, existing)
      assert result == :no_match
    end

    test "no dependency metadata = no_match" do
      candidate = %{id: "vuln-002", cve: "CVE-2024-1234"}
      result = VulnDeduplication.check_dependency(candidate, [])
      assert result == :no_match
    end
  end

  describe "check_structural/2" do
    test "same endpoint + target + title = duplicate" do
      candidate = %{
        id: "vuln-002",
        title: "SQL Injection in login",
        target: "https://example.com",
        endpoint: "/api/login"
      }

      existing = [
        %{
          id: "vuln-001",
          title: "SQL Injection in /api/login",
          target: "https://example.com",
          endpoint: "/api/login"
        }
      ]

      result = VulnDeduplication.check_structural(candidate, existing)
      assert result.is_duplicate == true
      assert result.duplicate_id == "vuln-001"
    end

    test "different endpoint = NOT duplicate" do
      candidate = %{
        id: "vuln-002",
        title: "SQL Injection in search",
        target: "https://example.com",
        endpoint: "/api/search"
      }

      existing = [
        %{
          id: "vuln-001",
          title: "SQL Injection in login",
          target: "https://example.com",
          endpoint: "/api/login"
        }
      ]

      result = VulnDeduplication.check_structural(candidate, existing)
      assert result.is_duplicate == false
    end

    test "no existing findings = not duplicate" do
      candidate = %{id: "vuln-001", title: "XSS", target: "https://example.com", endpoint: "/"}
      result = VulnDeduplication.check_structural(candidate, [])
      assert result.is_duplicate == false
    end
  end

  describe "check/2" do
    test "uses dependency fast path when available" do
      candidate = %{
        id: "vuln-002",
        title: "lodash vulnerability",
        cve: "CVE-2024-1234",
        dependency_metadata: %{package_name: "lodash", package_ecosystem: "npm"}
      }

      existing = [
        %{
          id: "vuln-001",
          title: "lodash CVE",
          cve: "CVE-2024-1234",
          dependency_metadata: %{package_name: "lodash", package_ecosystem: "npm"}
        }
      ]

      {:ok, result} = VulnDeduplication.check(candidate, existing)
      assert result.is_duplicate == true
      assert result.confidence == 1.0
    end

    test "falls back to structural when no dependency metadata" do
      candidate = %{
        id: "vuln-002",
        title: "SQL Injection",
        target: "https://example.com",
        endpoint: "/api/login"
      }

      existing = [
        %{
          id: "vuln-001",
          title: "SQL Injection",
          target: "https://example.com",
          endpoint: "/api/login"
        }
      ]

      {:ok, result} = VulnDeduplication.check(candidate, existing)
      assert result.is_duplicate == true
    end
  end
end
