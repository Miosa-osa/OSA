defmodule OptimalSystemAgent.Security.ChainSummaryTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.{ChainSummary, NotesStore, ShadowGraph}

  setup do
    session_id = "chain-test-#{System.unique_integer([:positive])}"
    {:ok, _} = NotesStore.ensure_started(session_id)

    on_exit(fn ->
      NotesStore.stop(session_id)
      ChainSummary.clear(session_id)
    end)

    {:ok, session_id: session_id}
  end

  describe "build/2" do
    test "summarizes an empty engagement", %{session_id: sid} do
      summary = ChainSummary.build(sid, notes: [], graph: ShadowGraph.new())
      assert summary.total_notes == 0
      assert summary.hosts == []
      assert summary.top_credential == nil
      assert summary.top_vulnerability == nil
      assert summary.insights == []
    end

    test "counts notes by category", %{session_id: sid} do
      notes = [
        %{category: :credential, key: "c1", username: "a", target: "10.0.0.1", confidence: :high},
        %{
          category: :vulnerability,
          key: "v1",
          target: "10.0.0.1",
          cve: "CVE-1",
          confidence: :high
        },
        %{category: :finding, key: "f1", target: "10.0.0.1", confidence: :medium}
      ]

      summary = ChainSummary.build(sid, notes: notes, graph: ShadowGraph.new())
      assert summary.counts[:credential] == 1
      assert summary.counts[:vulnerability] == 1
      assert summary.counts[:finding] == 1
      assert summary.total_notes == 3
    end

    test "surfaces the highest-confidence credential", %{session_id: sid} do
      notes = [
        %{
          category: :credential,
          key: "c1",
          username: "low",
          target: "10.0.0.1",
          confidence: :low
        },
        %{
          category: :credential,
          key: "c2",
          username: "high",
          target: "10.0.0.2",
          confidence: :high
        }
      ]

      summary = ChainSummary.build(sid, notes: notes, graph: ShadowGraph.new())
      assert summary.top_credential.username == "high"
    end

    test "includes graph hosts and insights", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "f1", %{
          category: :finding,
          content: "nmap",
          target: "10.0.0.1",
          services: [%{port: 22, protocol: "tcp"}]
        })

      graph = NotesStore.graph(sid)
      summary = ChainSummary.build(sid, notes: NotesStore.list(sid), graph: graph)
      assert length(summary.hosts) == 1
      assert summary.services_count == 1
    end

    test "extracts open questions from info notes", %{session_id: sid} do
      notes = [
        %{
          category: :info,
          key: "q1",
          content: "is the API behind a WAF?",
          metadata: %{"question" => "Is the API behind a WAF?"}
        }
      ]

      summary = ChainSummary.build(sid, notes: notes, graph: ShadowGraph.new())
      assert length(summary.open_questions) == 1
      assert String.contains?(hd(summary.open_questions), "WAF")
    end
  end

  describe "render/1" do
    test "produces a prompt-injectable block", %{session_id: sid} do
      summary = ChainSummary.build(sid, notes: [], graph: ShadowGraph.new())
      text = ChainSummary.render(summary)
      assert String.contains?(text, "<engagement_summary>")
      assert String.contains?(text, "</engagement_summary>")
      assert String.contains?(text, "Notes:")
    end
  end

  describe "save/2 and load/1" do
    test "round-trips a summary through disk", %{session_id: sid} do
      summary =
        ChainSummary.build(sid,
          notes: [],
          graph: ShadowGraph.new(),
          phase: %{name: "Recon", status: :in_progress, entry_criteria: [], exit_criteria: []}
        )

      :ok = ChainSummary.save(sid, summary)
      {:ok, loaded} = ChainSummary.load(sid)
      assert loaded.session_id == sid
      assert loaded.total_notes == 0
    end

    test "load on missing file returns error", %{session_id: sid} do
      ChainSummary.clear(sid)
      assert {:error, _} = ChainSummary.load(sid)
    end
  end
end

defmodule OptimalSystemAgent.Security.PlaybookTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.{Playbook, PlaybookStore}

  setup do
    session_id = "playbook-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> PlaybookStore.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "definitions" do
    test "includes core and 0-day playbooks" do
      ids = Playbook.available()
      assert :web_app in ids
      assert :network in ids
      assert :full_engagement in ids
      assert :whitebox in ids
      assert :ctf in ids
      assert :ci_scan in ids
      assert :cloud_engagement in ids
      assert :kubernetes in ids
      assert :active_directory in ids
    end

    test "web_app has 6 phases" do
      {:ok, pb} = Playbook.get(:web_app)
      assert Playbook.phase_count(pb) == 6
    end

    test "full_engagement has 8 phases" do
      {:ok, pb} = Playbook.get(:full_engagement)
      assert Playbook.phase_count(pb) == 8
    end

    test "whitebox, ctf, and ci_scan playbooks are well-formed" do
      {:ok, wb} = Playbook.get(:whitebox)
      {:ok, ctf} = Playbook.get(:ctf)
      {:ok, ci} = Playbook.get(:ci_scan)
      assert Playbook.phase_count(wb) == 5
      assert Playbook.phase_count(ctf) == 4
      assert Playbook.phase_count(ci) == 4
      {:ok, phase} = Playbook.phase_at(wb, 0)
      assert phase.entry_criteria != []
      assert phase.guidance =~ "Whitebox"
    end

    test "unknown playbook returns error" do
      assert {:error, _} = Playbook.get(:bogus)
    end

    test "phases have entry and exit criteria" do
      {:ok, pb} = Playbook.get(:web_app)
      {:ok, phase} = Playbook.phase_at(pb, 0)
      assert phase.entry_criteria != []
      assert phase.exit_criteria != []
    end
  end

  describe "session lifecycle" do
    test "start sets phase 0 to in_progress", %{session_id: sid} do
      {:ok, _} = Playbook.start(sid, :web_app)
      {:ok, phase} = Playbook.current(sid)
      assert phase.index == 0
      assert phase.status == :in_progress
      assert String.contains?(phase.name, "Scoping")
    end

    test "advance moves to the next phase", %{session_id: sid} do
      {:ok, _} = Playbook.start(sid, :web_app)
      {:ok, phase} = Playbook.advance(sid)
      assert phase.index == 1
      assert phase.status == :in_progress
    end

    test "advance past the last phase returns :complete", %{session_id: sid} do
      {:ok, pb} = Playbook.get(:web_app)
      {:ok, _} = Playbook.start(sid, :web_app)

      # Advance through all phases
      for _ <- 1..Playbook.phase_count(pb) do
        Playbook.advance(sid)
      end

      assert :complete = Playbook.advance(sid)
    end

    test "current without start returns error", %{session_id: sid} do
      assert {:error, _} = Playbook.current(sid)
    end

    test "phases lists all phases with statuses", %{session_id: sid} do
      {:ok, _} = Playbook.start(sid, :web_app)
      {:ok, _} = Playbook.advance(sid)
      {:ok, phases} = Playbook.phases(sid)
      assert length(phases) == 6
      # Phase 0 should be complete, phase 1 in_progress
      [first | rest] = phases
      assert first.status == :complete
      assert hd(rest).status == :in_progress
    end

    test "set_status changes the current phase status", %{session_id: sid} do
      {:ok, _} = Playbook.start(sid, :web_app)
      :ok = Playbook.set_status(sid, :skipped)
      {:ok, phase} = Playbook.current(sid)
      assert phase.status == :skipped
    end
  end

  describe "render_phase/1" do
    test "produces a prompt block with criteria", %{session_id: sid} do
      {:ok, _} = Playbook.start(sid, :web_app)
      {:ok, phase} = Playbook.current(sid)
      text = Playbook.render_phase(phase)
      assert String.contains?(text, "<current_phase>")
      assert String.contains?(text, "Exit criteria")
    end
  end
end

defmodule OptimalSystemAgent.Security.SarifReportTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.{SarifReport, NotesStore}

  setup do
    session_id = "sarif-test-#{System.unique_integer([:positive])}"
    {:ok, _} = NotesStore.ensure_started(session_id)
    on_exit(fn -> NotesStore.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "generate/2" do
    test "produces a valid SARIF 2.1.0 structure", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "v1", %{
          category: :vulnerability,
          content: "SQL injection in /api/users",
          target: "https://example.com",
          url: "https://example.com/api/users",
          cve: "CVE-2024-1234",
          confidence: :high
        })

      {:ok, report} = SarifReport.generate(sid)
      assert SarifReport.valid?(report)
      assert report["version"] == "2.1.0"
      [run] = report["runs"]
      assert run["tool"]["driver"]["name"] == "OSA"
      results = run["results"]
      assert length(results) == 1
      [result] = results
      assert SarifReport.result_valid?(result)
      assert result["ruleId"] == "CVE-2024-1234"
      assert result["level"] == "error"
    end

    test "empty notes produce an empty results array", %{session_id: sid} do
      {:ok, report} = SarifReport.generate(sid)
      assert SarifReport.valid?(report)
      [run] = report["runs"]
      assert run["results"] == []
    end

    test "confidence maps to SARIF level", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "v_low", %{
          category: :vulnerability,
          content: "low conf vuln",
          target: "10.0.0.1",
          cve: "CVE-2024-1",
          confidence: :low
        })

      {:ok, report} = SarifReport.generate(sid)
      [run] = report["runs"]
      [result] = run["results"]
      assert result["level"] == "note"
    end

    test "results have partialFingerprints for dedup", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "v1", %{
          category: :vulnerability,
          content: "vuln",
          target: "10.0.0.1",
          cve: "CVE-2024-1",
          confidence: :medium
        })

      {:ok, report} = SarifReport.generate(sid)
      [run] = report["runs"]
      [result] = run["results"]
      assert Map.has_key?(result, "partialFingerprints")
      assert Map.has_key?(result["partialFingerprints"], "primary")
    end
  end

  describe "valid?/1" do
    test "rejects wrong version" do
      refute SarifReport.valid?(%{"version" => "1.0", "runs" => []})
    end

    test "rejects missing runs" do
      refute SarifReport.valid?(%{"version" => "2.1.0"})
    end
  end
end

defmodule OptimalSystemAgent.Security.CodeFixTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.{CodeFix, CodeFixStore}

  setup do
    session_id = "codefix-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> CodeFixStore.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "record/2" do
    test "records a valid code fix", %{session_id: sid} do
      {:ok, fix} =
        CodeFix.record(sid, %{
          "finding_key" => "vuln_sqli",
          "file_path" => "src/api/users.py",
          "fix_before" => "query = f\"SELECT * FROM users WHERE id={id}\"",
          "fix_after" => "query = \"SELECT * FROM users WHERE id=?\"",
          "language" => "python",
          "explanation" => "Parameterized query prevents SQL injection."
        })

      assert fix.finding_key == "vuln_sqli"
      assert fix.file_path == "src/api/users.py"
    end

    test "rejects a fix missing required fields", %{session_id: sid} do
      {:error, reason} =
        CodeFix.record(sid, %{
          "finding_key" => "v1",
          "file_path" => "src/x.py"
        })

      assert String.contains?(reason, "fix_before")
    end

    test "accepts atom keys too", %{session_id: sid} do
      {:ok, fix} =
        CodeFix.record(sid, %{
          finding_key: "v1",
          file_path: "src/x.py",
          fix_before: "bad",
          fix_after: "good",
          explanation: "why"
        })

      assert fix.finding_key == "v1"
    end
  end

  describe "get/2 and list/1" do
    test "retrieves a recorded fix", %{session_id: sid} do
      {:ok, _} =
        CodeFix.record(sid, %{
          "finding_key" => "v1",
          "file_path" => "x.py",
          "fix_before" => "bad",
          "fix_after" => "good",
          "explanation" => "why"
        })

      {:ok, fix} = CodeFix.get(sid, "v1")
      assert fix.fix_before == "bad"
      assert fix.fix_after == "good"
    end

    test "get on missing fix returns :not_found", %{session_id: sid} do
      assert :not_found = CodeFix.get(sid, "nope")
    end

    test "list returns all fixes", %{session_id: sid} do
      {:ok, _} =
        CodeFix.record(sid, %{
          "finding_key" => "v1",
          "file_path" => "a.py",
          "fix_before" => "b",
          "fix_after" => "g",
          "explanation" => ""
        })

      {:ok, _} =
        CodeFix.record(sid, %{
          "finding_key" => "v2",
          "file_path" => "b.py",
          "fix_before" => "b",
          "fix_after" => "g",
          "explanation" => ""
        })

      {:ok, fixes} = CodeFix.list(sid)
      assert length(fixes) == 2
    end
  end

  describe "rendering" do
    test "render_diff produces a diff block", %{session_id: sid} do
      {:ok, fix} =
        CodeFix.record(sid, %{
          "finding_key" => "v1",
          "file_path" => "x.py",
          "fix_before" => "bad code",
          "fix_after" => "good code",
          "explanation" => "why"
        })

      diff = CodeFix.render_diff(fix)
      assert String.contains?(diff, "<code_fix")
      assert String.contains?(diff, "-bad code")
      assert String.contains?(diff, "+good code")
      assert String.contains?(diff, "Explanation: why")
    end

    test "render_report produces a section with all fixes", %{session_id: sid} do
      {:ok, _} =
        CodeFix.record(sid, %{
          "finding_key" => "v1",
          "file_path" => "x.py",
          "fix_before" => "b",
          "fix_after" => "g",
          "explanation" => ""
        })

      {:ok, text} = CodeFix.render_report(sid)
      assert String.contains?(text, "<code_fixes>")
      assert String.contains?(text, "v1")
    end

    test "render_report with no fixes says so", %{session_id: sid} do
      {:ok, text} = CodeFix.render_report(sid)
      assert String.contains?(text, "No code fixes")
    end
  end
end

defmodule OptimalSystemAgent.Security.SteerTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.{Steer, SteerStore}

  setup do
    session_id = "steer-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> SteerStore.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "inject/2 and consume/1" do
    test "inject then consume returns the directive one-shot", %{session_id: sid} do
      {:ok, _} = Steer.inject(sid, "Stop the nmap scan. Pivot to /api/ on 10.0.0.5.")
      assert Steer.pending?(sid)
      {:steer, directive} = Steer.consume(sid)
      assert String.contains?(directive.body, "Pivot to /api/")
      # Consumed — no longer pending
      refute Steer.pending?(sid)
      assert :none = Steer.consume(sid)
    end

    test "consume with no pending steer returns :none", %{session_id: sid} do
      assert :none = Steer.consume(sid)
    end

    test "latest inject overwrites a pending one", %{session_id: sid} do
      {:ok, _} = Steer.inject(sid, "first directive")
      {:ok, _} = Steer.inject(sid, "second directive")
      {:steer, directive} = Steer.consume(sid)
      assert directive.body == "second directive"
    end

    test "pending? reflects state", %{session_id: sid} do
      refute Steer.pending?(sid)
      {:ok, _} = Steer.inject(sid, "test")
      assert Steer.pending?(sid)
      Steer.consume(sid)
      refute Steer.pending?(sid)
    end
  end

  describe "render/1" do
    test "produces a user_steer block", %{session_id: sid} do
      {:ok, directive} = Steer.inject(sid, "Narrow scope to 10.0.0.5 only.")
      text = Steer.render(directive)
      assert String.contains?(text, "<user_steer>")
      assert String.contains?(text, "Narrow scope")
      assert String.contains?(text, "authoritative instruction")
    end
  end
end

defmodule OptimalSystemAgent.BudgetPauseTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Budget

  # Budget is a singleton GenServer. We test pause/resume against the real
  # process, then reset state at the end so other tests aren't affected.
  setup do
    # Ensure not paused at start
    if Budget.paused?(), do: Budget.resume()
    on_exit(fn -> if Budget.paused?(), do: Budget.resume() end)
    :ok
  end

  describe "pause/resume" do
    test "pause halts spending and resume restores it" do
      # Record some spend first
      Budget.record_cost(:openai, "gpt-4", 1000, 1000, "pause-test")
      {:ok, before} = Budget.get_status()
      spent_before = before.daily_spent

      assert spent_before > 0.0

      # Pause
      :ok = Budget.pause()
      assert Budget.paused?()
      {:ok, status} = Budget.get_status()
      assert status.paused == true

      # Record spend while paused — should NOT accumulate
      Budget.record_cost(:openai, "gpt-4", 5000, 5000, "pause-test")
      {:ok, after_paused} = Budget.get_status()
      assert after_paused.daily_spent == spent_before

      # Resume
      :ok = Budget.resume()
      refute Budget.paused?()

      # Now spend accumulates again
      Budget.record_cost(:openai, "gpt-4", 1000, 1000, "pause-test")
      {:ok, after_resume} = Budget.get_status()
      assert after_resume.daily_spent > spent_before
    end

    test "toggle_pause flips the state" do
      initial = Budget.paused?()
      :ok = Budget.toggle_pause()
      assert Budget.paused?() == not initial
      :ok = Budget.toggle_pause()
      assert Budget.paused?() == initial
    end

    test "paused? reflects get_status.paused" do
      Budget.pause()
      {:ok, status} = Budget.get_status()
      assert status.paused == Budget.paused?()
      Budget.resume()
    end
  end
end
