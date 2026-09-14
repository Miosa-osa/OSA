defmodule OptimalSystemAgent.Tools.Builtins.SecurityIntelPipelineEvalTest do
  @moduledoc """
  End-to-end pipeline eval for OSA's security_intel tool actions: full
  vulnerability-note -> graph -> attack orchestration -> exploit/queue ->
  chains/report-gate path, plus false-positive resistance (exploit_judge),
  severity discipline (report_gate_check), dedup, and SARIF. Real modules only —
  no mocks; per-session isolation like SecurityIntelNewActionsTest.
  """
  use ExUnit.Case, async: false
  @tag :pipeline_eval

  alias OptimalSystemAgent.Tools.Builtins.SecurityIntel
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Security.NotesStore

  setup do
    session_id = "intel-pipe-#{System.unique_integer([:positive])}"
    ctx = %UseContext{UseContext.empty() | session_id: session_id, permission_tier: :full}

    on_exit(fn ->
      NotesStore.stop(session_id)
      name = String.to_atom("osa_attack_ora_#{session_id}")
      if pid = Process.whereis(name), do: GenServer.stop(pid)
    end)

    {:ok, session_id: session_id, ctx: ctx}
  end

  defp run(action, ctx, extra \\ %{}) do
    SecurityIntel.execute(Map.merge(%{"action" => action}, extra), ctx)
  end

  # ── 1. FULL PIPELINE ────────────────────────────────────────────────────────

  test "full pipeline: notes -> graph hosts -> attack feed/run/next_target", %{
    ctx: ctx,
    session_id: sid
  } do
    targets = ["10.0.0.5", "192.168.1.44", "172.16.0.3"]

    for {key, target} <- Enum.zip(["vuln-1", "vuln-2", "cve-note"], targets) do
      {:ok, body} =
        run("note_create", ctx, %{
          "key" => key,
          "note" => %{
            "category" => "vulnerability",
            "target" => target,
            "cve" => "CVE-2021-44228",
            "weaknesses" => ["SQL injection"],
            "content" => "synthetic finding on #{target}"
          }
        })

      assert is_binary(body) and body != ""
    end

    {:ok, insights} = run("graph_insights", ctx)
    assert is_binary(insights) and insights != ""

    for target <- targets do
      {:ok, :ok} =
        run("attack_feed", ctx, %{
          "finding" => %{
            "category" => "vulnerability",
            "target" => target,
            "cve" => "CVE-2021-44228",
            "content" => "synthetic"
          }
        })
    end

    assert {:results, state} = run("attack_run", ctx)
    assert is_map(state) and is_list(state.weapons) and length(state.weapons) > 0

    result = run("attack_next_target", ctx)

    case result do
      {:ok, %{} = target} -> assert is_map(target)
      {:ok, msg} when is_binary(msg) -> assert msg =~ "target"
      other -> flunk("unexpected: #{inspect(other)}")
    end

    assert Process.whereis(String.to_atom("osa_attack_ora_#{sid}")) |> is_pid()

    {:ok, body} = run("chain_find", ctx)
    assert is_list(body.chains)
    assert body.count == length(body.chains)

    {:ok, b1} =
      run("queue_put", ctx, %{"class" => "sqli", "candidate" => %{"target" => "10.0.0.5"}})

    assert b1.queued == "sqli"

    {:ok, msg2} = run("queue_assert", ctx, %{"class" => "sqli"})
    assert is_binary(msg2) and msg2 =~ "sqli"
  end

  test "exploit_judge rejects unsupported claims and distinguishes a matched receipt", %{ctx: ctx} do
    assert {:rejected, reasons} =
             run("exploit_judge", ctx, %{
               "receipt" => %{"class" => "rce", "evidence" => ["the model says it worked"]}
             })

    assert Enum.any?(reasons, &String.contains?(&1, "empty body"))

    receipt = %{
      "class" => "rce",
      "status" => 200,
      "body" => "fixture response: marker-8472",
      "expected" => %{"stdout_marker" => "marker-8472"}
    }

    assert {:confirmed, ["stdout marker in body"]} =
             run("exploit_judge", ctx, %{"receipt" => receipt})

    assert {:inconclusive, ["no class-appropriate receipt"]} =
             run("exploit_judge", ctx, %{
               "receipt" => Map.put(receipt, "body", "ordinary harmless response")
             })

    assert {:inconclusive, ["ssrf 5xx is a hop not proof"]} =
             run("exploit_judge", ctx, %{
               "receipt" => %{
                 "class" => "ssrf",
                 "status" => 502,
                 "body" => "upstream unavailable"
               }
             })
  end

  test "report gate requires evidence and derives severity from the vector", %{ctx: ctx} do
    finding = %{
      "title" => "synthetic critical finding",
      "severity" => "critical",
      "cvss_vector" => "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H",
      "cwe" => "CWE-89"
    }

    assert {:error, reasons} = run("report_gate_check", ctx, %{"finding" => finding})
    assert reasons == ["missing evidence (poc, evidence_path, evidence_id, or evidence_sha256)"]

    evidenced = Map.put(finding, "poc", "synthetic fixture receipt marker-8472")
    assert {:ok, result} = run("report_gate_check", ctx, %{"finding" => evidenced})
    assert result.cvss_score == 9.8
    assert result.severity == :critical
    assert result.cwe == "CWE-89"

    low = Map.put(evidenced, "cvss_vector", "CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:U/C:L/I:N/A:N")
    assert {:ok, lowered} = run("report_gate_check", ctx, %{"finding" => low})
    assert lowered.cvss_score < 4.0
    assert lowered.severity == :low

    assert {:error, invalid_reasons} =
             run("report_gate_check", ctx, %{
               "finding" => Map.put(evidenced, "cvss_vector", "invalid")
             })

    assert Enum.any?(invalid_reasons, &String.contains?(&1, "invalid CVSS vector"))
  end

  test "dedup identifies the same endpoint and keeps a distinct endpoint", %{ctx: ctx} do
    assert {:ok, _} =
             run("note_create", ctx, %{
               "key" => "dup-1",
               "note" => %{
                 "category" => "vulnerability",
                 "target" => "10.9.9.9",
                 "url" => "https://fixture.invalid/item/1",
                 "cve" => "CVE-2024-0001",
                 "content" => "duplicate fixture"
               }
             })

    candidate = %{
      "target" => "10.9.9.9",
      "endpoint" => "https://fixture.invalid/item/1",
      "cve" => "CVE-2024-0001",
      "title" => "duplicate fixture"
    }

    assert {:ok, duplicate} = run("dedup", ctx, %{"candidate" => candidate})
    assert String.starts_with?(duplicate, "DUPLICATE of dup-1 ")

    assert {:ok, distinct} =
             run("dedup", ctx, %{
               "candidate" => Map.put(candidate, "endpoint", "https://fixture.invalid/other")
             })

    assert String.starts_with?(distinct, "NOT a duplicate ")
  end

  test "SARIF tool writes parseable results with the recorded finding", %{
    ctx: ctx,
    session_id: sid
  } do
    directory = Path.join(System.tmp_dir!(), "osa-sarif-eval-#{sid}")
    previous = Application.fetch_env(:optimal_system_agent, :sarif_dir)
    Application.put_env(:optimal_system_agent, :sarif_dir, directory)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:optimal_system_agent, :sarif_dir, value)
        :error -> Application.delete_env(:optimal_system_agent, :sarif_dir)
      end

      File.rm_rf!(directory)
    end)

    assert {:ok, _} =
             run("note_create", ctx, %{
               "key" => "sarif-v",
               "note" => %{
                 "category" => "vulnerability",
                 "target" => "10.5.5.5",
                 "cve" => "CVE-2024-0002",
                 "content" => "sarif fixture"
               }
             })

    assert {:ok, response} = run("sarif_generate", ctx, %{"to_file" => true})
    path = Path.join(directory, "#{sid}.sarif.json")
    assert response == "SARIF report written to #{path}. 1 result(s)."
    report = path |> File.read!() |> Jason.decode!()
    assert report["version"] == "2.1.0"
    assert report["$schema"] == "https://json.schemastore.org/sarif-2.1.0.json"
    assert [run] = report["runs"]
    assert run["tool"]["driver"]["name"] == "OSA"
    assert [result] = run["results"]
    assert result["ruleId"] == "CVE-2024-0002"
    assert result["message"] == %{"text" => "sarif fixture"}
    assert result["properties"]["target"] == "10.5.5.5"
    assert result["properties"]["noteKey"] == "sarif-v"
    assert result["level"] in ["error", "warning", "note"]

    assert [%{"physicalLocation" => %{"artifactLocation" => %{"uri" => "10.5.5.5"}}}] =
             Enum.map(result["locations"], &Map.take(&1, ["physicalLocation"]))
  end
end
