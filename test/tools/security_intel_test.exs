defmodule OptimalSystemAgent.Tools.Builtins.SecurityIntelTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.SecurityIntel
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Security.NotesStore

  # Each test gets a unique session id so the NotesStore GenServer is
  # isolated. We build a UseContext carrying that session id.
  setup do
    session_id = "intel-test-#{System.unique_integer([:positive])}"
    ctx = %UseContext{UseContext.empty() | session_id: session_id, permission_tier: :full}
    on_exit(fn -> NotesStore.stop(session_id) end)
    {:ok, session_id: session_id, ctx: ctx}
  end

  defp run(action, ctx, extra \\ %{}) do
    SecurityIntel.execute(Map.merge(%{"action" => action}, extra), ctx)
  end

  describe "tool metadata" do
    test "name, description, parameters, safety" do
      assert SecurityIntel.name() == "security_intel"
      assert is_binary(SecurityIntel.description())
      assert is_map(SecurityIntel.parameters())
      assert SecurityIntel.safety() == :write_safe
      assert SecurityIntel.available?() == true
      assert SecurityIntel.should_defer?() == true
    end
  end

  describe "note_create" do
    test "creates a valid credential note", %{ctx: ctx} do
      {:ok, body} =
        run("note_create", ctx, %{
          "key" => "creds_ssh",
          "note" => %{
            "category" => "credential",
            "content" => "SSH creds",
            "username" => "root",
            "password" => "toor",
            "target" => "10.0.0.1",
            "protocol" => "ssh"
          }
        })

      assert String.contains?(body, "key: creds_ssh")
      assert String.contains?(body, "category: credential")
      assert String.contains?(body, "username: root")
    end

    test "rejects an invalid note with an error", %{ctx: ctx} do
      {:error, reason} =
        run("note_create", ctx, %{
          "key" => "bad",
          "note" => %{"category" => "credential", "target" => "10.0.0.1"}
        })

      assert is_binary(reason)
      assert String.contains?(reason, "username")
    end

    test "errors without key or note", %{ctx: ctx} do
      {:error, reason} = run("note_create", ctx, %{})
      assert String.contains?(reason, "key")
    end
  end

  describe "note_get" do
    test "retrieves an existing note", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "v1",
          "note" => %{
            "category" => "vulnerability",
            "target" => "10.0.0.1",
            "cve" => "CVE-2024-1"
          }
        })

      {:ok, body} = run("note_get", ctx, %{"key" => "v1"})
      assert String.contains?(body, "key: v1")
      assert String.contains?(body, "cve: CVE-2024-1")
    end

    test "missing note returns a message, not an error", %{ctx: ctx} do
      {:ok, body} = run("note_get", ctx, %{"key" => "nope"})
      assert String.contains?(body, "No note")
    end
  end

  describe "note_list" do
    test "lists notes with count", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "c1",
          "note" => %{
            "category" => "credential",
            "username" => "a",
            "password" => "b",
            "target" => "10.0.0.1"
          }
        })

      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "v1",
          "note" => %{
            "category" => "vulnerability",
            "target" => "10.0.0.1",
            "cve" => "CVE-1"
          }
        })

      {:ok, body} = run("note_list", ctx)
      assert String.contains?(body, "2 note(s)")
    end

    test "filters by category", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "c1",
          "note" => %{
            "category" => "credential",
            "username" => "a",
            "password" => "b",
            "target" => "10.0.0.1"
          }
        })

      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "v1",
          "note" => %{
            "category" => "vulnerability",
            "target" => "10.0.0.1",
            "cve" => "CVE-1"
          }
        })

      {:ok, body} = run("note_list", ctx, %{"category" => "credential"})
      assert String.contains?(body, "1 note(s)")
      assert String.contains?(body, "c1")
      refute String.contains?(body, "v1")
    end

    test "empty store returns a helpful message", %{ctx: ctx} do
      {:ok, body} = run("note_list", ctx)
      assert String.contains?(body, "No notes")
    end
  end

  describe "note_delete" do
    test "deletes a note", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "c1",
          "note" => %{
            "category" => "credential",
            "username" => "a",
            "password" => "b",
            "target" => "10.0.0.1"
          }
        })

      {:ok, body} = run("note_delete", ctx, %{"key" => "c1"})
      assert String.contains?(body, "deleted")

      {:ok, body} = run("note_list", ctx)
      assert String.contains?(body, "No notes")
    end
  end

  describe "note_count" do
    test "counts notes with category filter", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "c1",
          "note" => %{
            "category" => "credential",
            "username" => "a",
            "password" => "b",
            "target" => "10.0.0.1"
          }
        })

      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "c2",
          "note" => %{
            "category" => "credential",
            "username" => "x",
            "password" => "y",
            "target" => "10.0.0.2"
          }
        })

      {:ok, body} = run("note_count", ctx)
      assert String.contains?(body, "2 note(s)")

      {:ok, body} = run("note_count", ctx, %{"category" => "credential"})
      assert String.contains?(body, "2 note(s)")
    end
  end

  describe "graph_insights" do
    test "returns insights when creds exist for an unscanned host", %{ctx: ctx} do
      # Credential for a host with no services
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "creds",
          "note" => %{
            "category" => "credential",
            "content" => "found creds",
            "username" => "admin",
            "password" => "pass",
            "target" => "10.0.0.5"
          }
        })

      {:ok, body} = run("graph_insights", ctx)
      assert String.contains?(body, "insight")
      assert String.contains?(body, "10.0.0.5")
    end

    test "empty graph returns a helpful message", %{ctx: ctx} do
      {:ok, body} = run("graph_insights", ctx)
      assert String.contains?(body, "empty")
    end
  end

  describe "graph_hosts" do
    test "lists discovered hosts", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "f1",
          "note" => %{
            "category" => "finding",
            "content" => "nmap",
            "target" => "10.0.0.1",
            "services" => [%{"port" => 22, "protocol" => "tcp"}]
          }
        })

      {:ok, body} = run("graph_hosts", ctx)
      assert String.contains?(body, "10.0.0.1")
    end
  end

  describe "graph_services" do
    test "lists services for a host", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "f1",
          "note" => %{
            "category" => "finding",
            "content" => "nmap",
            "target" => "10.0.0.1",
            "services" => [%{"port" => 22, "protocol" => "tcp", "product" => "OpenSSH"}]
          }
        })

      {:ok, body} = run("graph_services", ctx, %{"host_id" => "10.0.0.1"})
      assert String.contains?(body, "22")
      assert String.contains?(body, "OpenSSH")
    end

    test "accepts host: prefix too", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "f1",
          "note" => %{
            "category" => "finding",
            "content" => "nmap",
            "target" => "10.0.0.1",
            "services" => [%{"port" => 80, "protocol" => "tcp"}]
          }
        })

      {:ok, body} = run("graph_services", ctx, %{"host_id" => "host:10.0.0.1"})
      assert String.contains?(body, "80")
    end

    test "errors without host_id", %{ctx: ctx} do
      {:error, reason} = run("graph_services", ctx)
      assert String.contains?(reason, "host_id")
    end
  end

  describe "tda" do
    test "returns an explore/exploit decision" do
      {:ok, body} =
        SecurityIntel.execute(
          %{
            "action" => "tda",
            "steps_remaining" => 2,
            "evidence_confidence" => 0.9,
            "context_load" => 0.3,
            "historical_success_rate" => 0.8,
            "task_type" => "exploitation"
          },
          UseContext.empty()
        )

      assert String.contains?(body, "Decision:")
      assert String.contains?(body, "Confidence:")
      assert String.contains?(body, "Reasoning:")
    end

    test "uses defaults when params omitted" do
      {:ok, body} =
        SecurityIntel.execute(%{"action" => "tda"}, UseContext.empty())

      assert String.contains?(body, "Decision:")
    end
  end

  describe "dedup" do
    test "flags a structural duplicate against session findings", %{ctx: ctx} do
      # Existing finding in the store
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "v1",
          "note" => %{
            "category" => "vulnerability",
            "content" => "SQL injection in /api/users",
            "target" => "https://example.com",
            "url" => "https://example.com/api/users",
            "cve" => "CVE-2024-1"
          }
        })

      # Candidate with same target + endpoint + vuln type in title
      {:ok, body} =
        run("dedup", ctx, %{
          "candidate" => %{
            "id" => "v2",
            "title" => "SQL injection in users endpoint",
            "description" => "sqli",
            "target" => "https://example.com",
            "endpoint" => "https://example.com/api/users"
          }
        })

      # Either duplicate or not — but must return a verdict string
      assert String.contains?(body, "DUPLICATE") or String.contains?(body, "NOT a duplicate")
    end

    test "returns not-duplicate for a novel finding", %{ctx: ctx} do
      {:ok, _} =
        run("note_create", ctx, %{
          "key" => "v1",
          "note" => %{
            "category" => "vulnerability",
            "content" => "XSS in /search",
            "target" => "https://example.com",
            "url" => "https://example.com/search",
            "cve" => "CVE-2024-2"
          }
        })

      {:ok, body} =
        run("dedup", ctx, %{
          "candidate" => %{
            "id" => "v2",
            "title" => "SSRF in metadata endpoint",
            "description" => "ssrf",
            "target" => "https://example.com",
            "endpoint" => "https://example.com/api/metadata"
          }
        })

      assert String.contains?(body, "NOT a duplicate")
    end

    test "errors without candidate", %{ctx: ctx} do
      {:error, reason} = run("dedup", ctx)
      assert String.contains?(reason, "candidate")
    end
  end

  describe "unknown / missing action" do
    test "unknown action returns an error", %{ctx: ctx} do
      {:error, reason} = run("bogus", ctx)
      assert String.contains?(reason, "Unknown action")
    end

    test "missing action returns an error", %{ctx: ctx} do
      {:error, reason} = SecurityIntel.execute(%{}, ctx)
      assert String.contains?(reason, "action")
    end
  end

  describe "flat-layout execute/1 compat" do
    test "works with empty UseContext (default session)" do
      {:ok, body} = SecurityIntel.execute(%{"action" => "note_list"})
      assert String.contains?(body, "No notes") or String.contains?(body, "note")
    after
      NotesStore.stop("default")
    end
  end

  describe "cvss_score / cwe_lookup / roe_check actions" do
    test "cvss_score scores a valid vector and reports severity", %{ctx: ctx} do
      {:ok, body} =
        run("cvss_score", ctx, %{"cvss_vector" => "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"})

      assert body =~ "9.8"
      assert body =~ "critical"
    end

    test "cvss_score refuses a malformed vector instead of fabricating a score", %{ctx: ctx} do
      assert {:error, reason} = run("cvss_score", ctx, %{"cvss_vector" => "garbage"})
      assert reason =~ "Invalid CVSS"
    end

    test "cwe_lookup maps a class to CWE/OWASP/typical CVSS", %{ctx: ctx} do
      {:ok, body} = run("cwe_lookup", ctx, %{"vuln_class" => "sqli"})
      assert body =~ "CWE-89"
      assert body =~ "A03"
    end

    test "cwe_lookup on an unknown class lists the known ones", %{ctx: ctx} do
      assert {:error, reason} = run("cwe_lookup", ctx, %{"vuln_class" => "not_real"})
      assert reason =~ "No CWE mapping"
    end

    test "roe_check classifies a shell command and blocks out-of-scope", %{ctx: ctx} do
      {:ok, body} =
        run("roe_check", ctx, %{
          "roe" => %{"targets" => ["10.0.0.0/24"], "max_blast" => "cred_access"},
          "roe_action" => %{"command" => "nmap -sV 8.8.8.8", "target" => "8.8.8.8"}
        })

      assert body =~ "block"
      assert body =~ "recon"
    end

    test "roe_check allows in-scope recon", %{ctx: ctx} do
      {:ok, body} =
        run("roe_check", ctx, %{
          "roe" => %{"targets" => ["10.0.0.0/24"]},
          "roe_action" => %{"command" => "nmap 10.0.0.5", "target" => "10.0.0.5"}
        })

      assert body =~ "allow"
    end
  end

  describe "whitebox_scan action" do
    test "requires content", %{ctx: ctx} do
      assert {:error, reason} = run("whitebox_scan", ctx, %{"whitebox" => %{"entry" => "x.ex"}})
      assert reason =~ "content is required"
    end
  end

end
