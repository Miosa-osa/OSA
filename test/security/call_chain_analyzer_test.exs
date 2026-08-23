defmodule OptimalSystemAgent.Security.CallChainAnalyzerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.CallChainAnalyzer, as: CCA

  # A stub runner distinguishes the TRACE call from the JUDGE call by the
  # system prompt, so one closure can drive the whole loop deterministically.
  defp runner(trace_map, judge_map) do
    fn messages ->
      sys = messages |> List.first() |> Map.get(:content, "")

      cond do
        String.contains?(sys, "next hop in the call chain") ->
          user = messages |> List.last() |> Map.get(:content, "")
          label = trace_key(user)
          {:ok, Jason.encode!(Map.get(trace_map, label, %{"next_symbols" => []}))}

        true ->
          class = judge_class(sys)
          {:ok, Jason.encode!(Map.get(judge_map, class, %{"exploitable" => false}))}
      end
    end
  end

  defp trace_key(user_text) do
    case Regex.run(~r/FILE: (\S+)/, user_text) do
      [_, k] -> k
      _ -> "?"
    end
  end

  defp judge_class(sys) do
    cond do
      String.contains?(sys, "SQL Injection") -> :sqli
      String.contains?(sys, "Remote Code Execution") -> :rce
      String.contains?(sys, "Cross-Site Scripting") -> :xss
      true -> :other
    end
  end

  test "traces user input across files and reports an exploitable SQLi with a CVSS score" do
    reader = fn
      "build_query" -> {:ok, "def build_query(id), do: \"SELECT * FROM t WHERE id=\" <> id"}
      _ -> :not_found
    end

    trace = %{
      "handler.ex" => %{
        "handles_user_input" => true,
        "input_sources" => ["params.id"],
        "next_symbols" => ["build_query"]
      },
      "build_query" => %{"next_symbols" => []}
    }

    judge = %{
      sqli: %{
        "exploitable" => true,
        "confidence" => "high",
        "source" => "handler.ex:params.id",
        "sink" => "build_query/1",
        "call_chain" => ["handler.ex", "build_query"],
        "reasoning" => "id is concatenated into the query unparameterized",
        "poc" => "id=1 OR 1=1",
        "cvss_vector" => "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
      }
    }

    {:ok, findings} =
      CCA.analyze(
        entry: "handler.ex",
        content: "def show(params), do: build_query(params.id)",
        vuln_classes: [:sqli],
        reader: reader,
        runner: runner(trace, judge)
      )

    assert [f] = findings
    assert f.vuln_class == :sqli
    assert f.exploitable
    assert f.confidence == :high
    assert f.sink == "build_query/1"
    assert f.cvss_score == 9.8
    assert f.severity == :critical
    assert f.call_chain == ["handler.ex", "build_query"]
    assert f.cwe == "CWE-89"
    assert f.owasp =~ "Injection"
  end

  test "a class the judge marks non-exploitable is dropped" do
    trace = %{"e" => %{"next_symbols" => []}}
    judge = %{rce: %{"exploitable" => false, "reasoning" => "input is validated"}}

    {:ok, findings} =
      CCA.analyze(
        entry: "e",
        content: "safe code",
        vuln_classes: [:rce],
        runner: runner(trace, judge)
      )

    assert findings == []
  end

  test "an exploitable finding with no CVSS vector still returns, unscored" do
    trace = %{"e" => %{"next_symbols" => []}}

    judge = %{
      xss: %{
        "exploitable" => true,
        "confidence" => "medium",
        "source" => "e:q",
        "sink" => "render",
        "reasoning" => "reflected without encoding",
        "poc" => "<svg onload=alert(1)>"
      }
    }

    {:ok, [f]} =
      CCA.analyze(
        entry: "e",
        content: "render(params.q)",
        vuln_classes: [:xss],
        runner: runner(trace, judge)
      )

    assert f.exploitable
    assert f.cvss_score == nil
    assert f.severity == nil
    assert f.poc =~ "onload"
  end

  test "max_depth bounds the trace so a cyclic/recursive chain terminates" do
    # Every symbol points to the next forever; a depth cap must stop it.
    reader = fn sym -> {:ok, "calls next from #{sym}"} end

    trace_runner = fn messages ->
      sys = messages |> List.first() |> Map.get(:content, "")

      if String.contains?(sys, "next hop in the call chain") do
        {:ok, Jason.encode!(%{"next_symbols" => ["deeper"]})}
      else
        {:ok, Jason.encode!(%{"exploitable" => false})}
      end
    end

    # Should simply terminate and return (no infinite loop / no crash).
    assert {:ok, _} =
             CCA.analyze(
               entry: "start",
               content: "seed",
               vuln_classes: [:rce],
               reader: reader,
               runner: trace_runner,
               max_depth: 3
             )
  end

  test "malformed runner output never crashes the analysis" do
    bad = fn _ -> {:ok, "totally not json <<<"} end

    assert {:ok, []} =
             CCA.analyze(entry: "e", content: "x", vuln_classes: [:sqli], runner: bad)
  end

  test "empty content is refused" do
    assert {:error, _} = CCA.analyze(content: "")
    assert {:error, _} = CCA.analyze([])
  end

  test "vuln_classes/0 covers the standard whitebox-reachable set" do
    for c <- [
          :rce,
          :sqli,
          :ssrf,
          :idor,
          :xss,
          :lfi,
          :path_traversal,
          :xxe,
          :ssti,
          :deserialization
        ] do
      assert c in CCA.vuln_classes()
      assert is_binary(CCA.analysis_prompt(c))
    end
  end
end
