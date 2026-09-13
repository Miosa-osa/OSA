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

  test "discover_entries seeds on request-handler content, not just filename", %{root: root} do
    File.write!(
      Path.join(root, "users_api.py"),
      "from fastapi import APIRouter\nr = APIRouter()\n"
    )

    entries = CiScan.discover_entries(root)
    bases = Enum.map(entries, &Path.basename/1)
    assert "users_api.py" in bases
  end

  test "changed_files includes a non-handler source file and excludes unlisted handlers", %{
    root: root
  } do
    File.write!(Path.join(root, "util.py"), "import os\nos.system('id')\n")

    entries = CiScan.discover_entries(root, changed_files: ["util.py"])
    bases = Enum.map(entries, &Path.basename/1)

    assert "util.py" in bases
    refute "router.ex" in bases
    refute "app.py" in bases
  end

  test "changed_files matches Path.join(root, rel) as well as the relative path", %{root: root} do
    File.write!(Path.join(root, "util.py"), "import os\nos.system('id')\n")
    abs = Path.join(root, "util.py")

    entries = CiScan.discover_entries(root, changed_files: [abs])
    bases = Enum.map(entries, &Path.basename/1)
    assert "util.py" in bases
  end

  test "since uses injected git and only returns that file when it exists", %{root: root} do
    File.write!(
      Path.join(root, "users_api.py"),
      "from fastapi import APIRouter\nr = APIRouter()\n"
    )

    git_fn = fn git_root, args ->
      assert git_root == root
      assert args == ["diff", "--name-only", "--diff-filter=ACMR", "HEAD~1"]
      {:ok, "users_api.py\n"}
    end

    entries = CiScan.discover_entries(root, since: "HEAD~1", git: git_fn)
    bases = Enum.map(entries, &Path.basename/1)
    assert "users_api.py" in bases
    refute "router.ex" in bases
    refute "app.py" in bases
  end

  test "git fn error returns no entries rather than the whole tree", %{root: root} do
    git_fn = fn _root, _args -> {:error, "fatal: not a git repository"} end
    assert CiScan.discover_entries(root, since: "HEAD~1", git: git_fn) == []
  end

  test "run summary.diff_scope is true when changed_files is passed", %{root: root} do
    analyzer = fn _opts -> {:ok, []} end

    assert {:ok, report} =
             CiScan.run(root: root, analyzer: analyzer, changed_files: ["router.ex"])

    assert report.summary.diff_scope == true
    assert report.summary.files_considered == 1
    assert report.entries_scanned == 1
  end

  test "run summary.diff_scope is false on a full scan", %{root: root} do
    analyzer = fn _opts -> {:ok, []} end
    assert {:ok, report} = CiScan.run(root: root, analyzer: analyzer)
    assert report.summary.diff_scope == false
    assert is_integer(report.summary.files_considered)
    assert report.summary.files_considered == report.entries_scanned
  end

  test "run returns error when since git fn fails", %{root: root} do
    git_fn = fn _root, _args -> {:error, "fatal: bad revision"} end

    assert {:error, reason} =
             CiScan.run(root: root, since: "HEAD~1", git: git_fn, analyzer: fn _ -> {:ok, []} end)

    assert is_binary(reason)
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
