defmodule OptimalSystemAgent.Security.EvalHarnessTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.EvalHarness

  @fixture_dir Path.expand("../fixtures/pentest_eval", __DIR__)
  @catalog Path.join(@fixture_dir, "catalog.json")

  @perfect [
    %{class: "sqli", file: "app.py"},
    %{class: "xss", file: "app.py"}
  ]

  describe "load_catalog/1" do
    test "catalog loads" do
      assert {:ok, catalog} = EvalHarness.load_catalog(@catalog)
      assert catalog["name"] == "osa-fixture-v1"
      assert length(catalog["cases"]) == 3

      ids = Enum.map(catalog["cases"], & &1["id"])
      assert ids == ["FIX-001", "FIX-002", "FIX-003"]
    end

    test "missing catalog errors" do
      assert {:error, msg} = EvalHarness.load_catalog("/no/such/osa-eval-catalog.json")
      assert is_binary(msg)
      assert msg =~ "catalog"
    end

    test "invalid JSON errors" do
      path =
        Path.join(System.tmp_dir!(), "osa-eval-bad-#{System.unique_integer([:positive])}.json")

      File.write!(path, "{not json")
      on_exit(fn -> File.rm(path) end)

      assert {:error, msg} = EvalHarness.load_catalog(path)
      assert is_binary(msg)
    end
  end

  describe "score/2" do
    setup do
      {:ok, catalog} = EvalHarness.load_catalog(@catalog)
      {:ok, catalog: catalog}
    end

    test "perfect findings yield precision 1 recall 1", %{catalog: catalog} do
      score = EvalHarness.score(catalog, @perfect)

      assert score.true_positives == 2
      assert score.false_positives == 0
      assert score.false_negatives == 0
      assert score.precision == 1.0
      assert score.recall == 1.0
      assert score.f0_5 == 1.0
      assert score.by_id["FIX-001"] == :tp
      assert score.by_id["FIX-002"] == :tp
      assert score.by_id["FIX-003"] == :tn
    end

    test "extra wrong class is FP and precision < 1", %{catalog: catalog} do
      findings = @perfect ++ [%{class: "idor", file: "app.py"}]
      score = EvalHarness.score(catalog, findings)

      assert score.true_positives == 2
      assert score.false_positives == 1
      assert score.false_negatives == 0
      assert score.precision < 1.0
      assert score.recall == 1.0
      assert score.by_id["FIX-003"] == :fp
    end

    test "missing must_find is FN", %{catalog: catalog} do
      findings = [%{class: "sqli", file: "app.py"}]
      score = EvalHarness.score(catalog, findings)

      assert score.true_positives == 1
      assert score.false_negatives == 1
      assert score.false_positives == 0
      assert score.recall < 1.0
      assert score.by_id["FIX-001"] == :tp
      assert score.by_id["FIX-002"] == :fn
      assert score.by_id["FIX-003"] == :tn
    end

    test "f0_5 uses the beta=0.5 formula", %{catalog: catalog} do
      findings = @perfect ++ [%{vuln_class: :idor, source: "app.py"}]
      score = EvalHarness.score(catalog, findings)

      b2 = 0.5 * 0.5
      p = score.precision
      r = score.recall
      expected = (1 + b2) * p * r / (b2 * p + r)

      assert_in_delta score.f0_5, expected, 1.0e-9
      assert score.f0_5 < 1.0
    end

    test "class atoms match strings and missing file still matches", %{catalog: catalog} do
      findings = [%{vuln_class: :sqli}, %{class: :xss, path: "app.py"}]
      score = EvalHarness.score(catalog, findings)

      assert score.by_id["FIX-001"] == :tp
      assert score.by_id["FIX-002"] == :tp
      assert score.precision == 1.0
      assert score.recall == 1.0
    end

    test "unmatched extra class counts as FP", %{catalog: catalog} do
      findings = @perfect ++ [%{class: "rce", file: "app.py"}]
      score = EvalHarness.score(catalog, findings)

      assert score.false_positives >= 1
      assert score.precision < 1.0
      assert score.by_id["FIX-001"] == :tp
      assert score.by_id["FIX-002"] == :tp
      assert score.by_id["FIX-003"] == :tn
    end
  end

  describe "run/1" do
    test "run with injected scanner scores the returned findings" do
      scanner = fn root ->
        assert root == @fixture_dir
        {:ok, @perfect}
      end

      assert {:ok, score} =
               EvalHarness.run(catalog: @catalog, root: @fixture_dir, scanner: scanner)

      assert score.precision == 1.0
      assert score.recall == 1.0
      assert score.f0_5 == 1.0
    end

    test "run with explicit findings skips the scanner" do
      scanner = fn _root -> flunk("scanner should not be called") end

      assert {:ok, score} =
               EvalHarness.run(
                 catalog: @catalog,
                 root: @fixture_dir,
                 findings: @perfect,
                 scanner: scanner
               )

      assert score.true_positives == 2
      assert score.false_positives == 0
    end

    test "default scanner finds SELECT concat and innerHTML, not the comment sink" do
      assert {:ok, score} = EvalHarness.run(catalog: @catalog, root: @fixture_dir)

      assert score.by_id["FIX-001"] == :tp
      assert score.by_id["FIX-002"] == :tp
      assert score.by_id["FIX-003"] == :tn
      assert score.precision == 1.0
      assert score.recall == 1.0
    end

    test "missing catalog errors" do
      assert {:error, msg} = EvalHarness.run([])
      assert is_binary(msg)

      assert {:error, _} = EvalHarness.run(catalog: "/no/such/osa-eval-catalog.json")
    end
  end
end
