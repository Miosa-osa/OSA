defmodule OptimalSystemAgent.Security.CiScanTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.CiScan

  setup do
    root = Path.join(System.tmp_dir!(), "osa-ci-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "router.ex"),
      "defmodule R do\n  def show(id), do: Repo.query(\"select \" <> id)\nend\n"
    )

    File.write!(Path.join(root, "app.py"), "from flask import Flask\napp = Flask(__name__)\n")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "discover_entries finds router.ex and app.py", %{root: root} do
    entries = CiScan.discover_entries(root)
    bases = Enum.map(entries, &Path.basename/1)
    assert "router.ex" in bases
    assert "app.py" in bases
  end

  test "injected analyzer with a critical finding fails the gate", %{root: root} do
    analyzer = fn opts ->
      if String.ends_with?(Keyword.get(opts, :entry, ""), "router.ex") do
        {:ok,
         [
           %{
             vuln_class: :sqli,
             severity: :critical,
             reasoning: "concat SQL",
             source: "router.ex",
             poc: "id=1"
           }
         ]}
      else
        {:ok, []}
      end
    end

    assert {:ok, report} = CiScan.run(root: root, analyzer: analyzer)
    assert report.failed?
    assert report.summary.critical == 1
    assert report.sarif["version"] == "2.1.0"
  end

  test "empty analyzer does not fail", %{root: root} do
    analyzer = fn _opts -> {:ok, []} end
    assert {:ok, report} = CiScan.run(root: root, analyzer: analyzer)
    refute report.failed?
    assert report.findings == []
  end

  test "sarif_from_findings has results" do
    sarif =
      CiScan.sarif_from_findings([%{vuln_class: :xss, severity: :medium, reasoning: "reflected"}])

    assert [%{"ruleId" => "xss", "level" => "warning"}] = hd(sarif["runs"])["results"]
  end

  test "missing root is an error" do
    assert {:error, _} = CiScan.run(root: "/no/such/osa-ci")
  end
end
