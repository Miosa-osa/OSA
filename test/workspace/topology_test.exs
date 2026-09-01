defmodule OptimalSystemAgent.Workspace.TopologyTest do
  @moduledoc """
  Real-fixture tests for constellation topology detection.

  These do not mock git. Every test runs against a temp tree containing an
  actual submodule, an actual nested independent repository, an actual Elixir
  umbrella and an actual pnpm workspace, built by `build_fixture/1` below —
  because the entire point of the module under test is that git's *real*
  behavior around nested repos is surprising, and a mock would encode the
  assumption we are trying to falsify.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.ContextDiscovery
  alias OptimalSystemAgent.Agent.Safety.PathCanon
  alias OptimalSystemAgent.Workspace.Topology
  alias OptimalSystemAgent.Workspace.Topology.Render
  alias OptimalSystemAgent.Workspace.Topology.Role

  setup do
    # `System.pid/0` (the OS pid of this BEAM) makes the name unique ACROSS
    # runs, not just within one: `unique_integer` alone collided with fixtures
    # left by earlier suites. Registered for cleanup BEFORE it is built, so a
    # fixture that raises mid-build cannot survive to collide again.
    root =
      Path.join(
        System.tmp_dir!(),
        "osa_topo_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    on_exit(fn -> File.rm_rf(root <> "_subsrc") end)

    root = build_fixture(root)
    on_exit(fn -> Topology.invalidate(:all) end)
    %{root: root}
  end

  # ── The blind spot itself ──────────────────────────────────────────────

  describe "git's view of the fixture (the bug being fixed)" do
    test "git ls-files collapses the nested repo and submodule to one entry each", %{root: root} do
      {out, 0} = git(["ls-files"], root)
      listed = String.split(out, "\n", trim: true)

      # Both appear — as bare gitlinks, with none of their contents.
      assert "miosa-compute" in listed
      assert "vendor/subm" in listed

      refute Enum.any?(listed, &String.starts_with?(&1, "miosa-compute/"))
      refute Enum.any?(listed, &String.starts_with?(&1, "vendor/subm/"))

      # …even though those files unquestionably exist on disk.
      assert File.regular?(Path.join(root, "miosa-compute/mix.exs"))
      assert File.regular?(Path.join(root, "vendor/subm/go.mod"))
    end

    test "topology sees the subtrees git hides", %{root: root} do
      topo = Topology.detect(root)
      paths = Enum.map(topo.components, & &1.path)

      assert "miosa-compute" in paths
      assert "vendor/subm" in paths
    end
  end

  # ── Classification ─────────────────────────────────────────────────────

  describe "classification" do
    test "nested independent repo is :nested_repo, not :submodule", %{root: root} do
      c = component(root, "miosa-compute")
      assert c.kind == :nested_repo
    end

    test "declared submodule is :submodule even though it also has a .git", %{root: root} do
      c = component(root, "vendor/subm")
      assert c.kind == :submodule
      assert File.exists?(Path.join(root, "vendor/subm/.git"))
    end

    test "umbrella apps are :workspace_member with the umbrella's type", %{root: root} do
      c = component(root, "apps/alpha")
      assert c.kind == :workspace_member
      assert c.workspace_type == :elixir_umbrella
    end

    test "pnpm packages are :workspace_member with the pnpm type", %{root: root} do
      c = component(root, "web/ui")
      assert c.kind == :workspace_member
      assert c.workspace_type == :pnpm_workspace
    end

    test "a plain directory with a manifest is :plain", %{root: root} do
      c = component(root, "sdks/python")
      assert c.kind == :plain
    end

    test "organizational dirs with no evidence are traversed, not listed", %{root: root} do
      paths = root |> Topology.detect() |> Map.fetch!(:components) |> Enum.map(& &1.path)

      # `sdks/` and `web/` hold components but are not components themselves.
      refute "sdks" in paths
      refute "web" in paths
      assert "sdks/python" in paths
    end
  end

  describe "workspace declarations" do
    test "detects both the umbrella and the pnpm workspace at the root", %{root: root} do
      types = root |> Topology.detect() |> Map.fetch!(:workspaces) |> Enum.map(& &1.type)

      assert :elixir_umbrella in types
      assert :pnpm_workspace in types
    end

    test "cargo workspace members are indexed", %{root: _root} do
      dir = tmp("cargo")

      write(dir, "Cargo.toml", """
      [workspace]
      members = ["crates/*"]
      """)

      write(dir, "crates/engine/Cargo.toml", "[package]\nname = \"engine\"\n")
      write(dir, "crates/engine/src/main.rs", "fn main() {}")
      on_exit(fn -> File.rm_rf(dir) end)

      topo = Topology.detect(dir)
      c = Enum.find(topo.components, &(&1.path == "crates/engine"))

      assert c.kind == :workspace_member
      assert c.workspace_type == :cargo_workspace
      assert c.language == "Rust"
      assert c.role == :app
    end

    test "go.work members are indexed", %{root: _root} do
      dir = tmp("gowork")
      write(dir, "go.work", "go 1.22\n\nuse ./svc\n")
      write(dir, "svc/go.mod", "module example.com/svc\n\ngo 1.22\n")
      write(dir, "svc/main.go", "package main\n")
      on_exit(fn -> File.rm_rf(dir) end)

      topo = Topology.detect(dir)
      c = Enum.find(topo.components, &(&1.path == "svc"))

      assert c.workspace_type == :go_workspace
      assert c.language == "Go"
    end
  end

  # ── Role inference ─────────────────────────────────────────────────────

  describe "role inference" do
    test "Phoenix app in the nested repo", %{root: root} do
      c = component(root, "miosa-compute")
      assert c.language == "Elixir"
      assert c.framework == "Phoenix"
      assert c.role == :app
    end

    test "Go app in the submodule (cmd/ is the entrypoint evidence)", %{root: root} do
      c = component(root, "vendor/subm")
      assert c.language == "Go"
      assert c.role == :app
    end

    test "umbrella app with a mod: callback is :app, without is :library", %{root: root} do
      assert component(root, "apps/alpha").role == :app
      assert component(root, "apps/beta").role == :library
    end

    test "package.json with a start script is :app, with only exports is :library", %{root: root} do
      ui = component(root, "web/ui")
      assert ui.role == :app
      assert ui.framework == "React"

      assert component(root, "web/core").role == :library
    end

    test "an sdks/ member is :sdk", %{root: root} do
      c = component(root, "sdks/python")
      assert c.role == :sdk
      assert c.language == "Python"
    end

    test "a terraform dir is :infra", %{root: root} do
      c = component(root, "infra/tf")
      assert c.role == :infra
      assert c.language == "Terraform"
    end

    test "a docs dir is :docs", %{root: root} do
      assert component(root, "docs").role == :docs
    end

    test "an unrecognizable component reports :unknown, never a guess" do
      dir = tmp("mystery")
      write(dir, "thing/package.json", ~s({"name":"thing","version":"1.0.0"}))
      on_exit(fn -> File.rm_rf(dir) end)

      c = Enum.find(Topology.detect(dir).components, &(&1.path == "thing"))
      assert c.role == :unknown
      assert Render.table(%{components: [c]}, width: 100) =~ "—"
    end

    test "role_label never invents a word for :unknown" do
      assert Role.role_label(:unknown) == "unknown"
    end
  end

  # ── Walk hygiene ───────────────────────────────────────────────────────

  describe "walk bounds" do
    test "skips node_modules / _build / deps / target", %{root: root} do
      paths = root |> Topology.detect() |> Map.fetch!(:components) |> Enum.map(& &1.path)

      refute Enum.any?(paths, &String.contains?(&1, "node_modules"))
      refute Enum.any?(paths, &String.contains?(&1, "_build"))
      refute Enum.any?(paths, &String.contains?(&1, "target"))
    end

    test "respects .gitignore", %{root: root} do
      paths = root |> Topology.detect() |> Map.fetch!(:components) |> Enum.map(& &1.path)
      refute "generated" in paths
    end

    test "honours max_depth", %{root: root} do
      shallow = Topology.detect(root, max_depth: 1)
      assert Enum.all?(shallow.components, &(&1.depth <= 1))
      assert "miosa-compute" in Enum.map(shallow.components, & &1.path)
      refute "apps/alpha" in Enum.map(shallow.components, & &1.path)
    end
  end

  # ── Caching ────────────────────────────────────────────────────────────

  describe "caching" do
    test "a second get/2 is served from cache (same fingerprint, no rewalk)", %{root: root} do
      first = Topology.get(root)
      # Marker only the cached copy can carry: mutate the tree WITHOUT touching
      # any fingerprinted file, then assert the cached answer is still returned.
      File.mkdir_p!(Path.join(root, "later/nothing"))

      second = Topology.get(root)
      assert Enum.map(second.components, & &1.path) == Enum.map(first.components, & &1.path)
    end

    test "editing .gitmodules invalidates the cache", %{root: root} do
      first = Topology.get(root)
      assert Enum.any?(first.components, &(&1.kind == :submodule))

      # Drop the submodule declaration: the same directory must now be
      # reclassified as a nested independent repo.
      File.write!(Path.join(root, ".gitmodules"), "")
      bump_mtime(Path.join(root, ".gitmodules"))

      second = Topology.get(root)
      assert Enum.find(second.components, &(&1.path == "vendor/subm")).kind == :nested_repo
    end

    test "editing a component manifest invalidates the cache", %{root: root} do
      assert component_cached(root, "web/core").role == :library

      write(root, "web/core/package.json", ~s({"name":"core","scripts":{"start":"node ."}}))
      bump_mtime(Path.join(root, "web/core/package.json"))

      assert component_cached(root, "web/core").role == :app
    end

    test "refresh: true forces a rewalk", %{root: root} do
      Topology.get(root)
      File.mkdir_p!(Path.join(root, "brandnew"))
      write(root, "brandnew/go.mod", "module example.com/brandnew\n")

      refreshed = Topology.get(root, refresh: true)
      assert "brandnew" in Enum.map(refreshed.components, & &1.path)
    end

    test "invalidate/1 drops the entry", %{root: root} do
      Topology.get(root)
      assert :ok = Topology.invalidate(root)
      assert %{components: [_ | _]} = Topology.get(root)
    end
  end

  # ── Enclosing-root resolution (the discovery fix) ──────────────────────

  describe "workspace_root/1" do
    test "climbs PAST a nested repo to the constellation root", %{root: root} do
      inner = Path.join(root, "miosa-compute")

      # git itself stops at the inner repo…
      {git_answer, 0} = git(["rev-parse", "--show-toplevel"], inner)
      # Both sides canonicalized: on macOS git answers with the PHYSICAL path
      # (/private/var/...) while the fixture was built from the raw
      # /var/... spelling — Path.expand/1 does not resolve that symlink.
      assert PathCanon.canonicalize(String.trim(git_answer)) ==
               PathCanon.canonicalize(inner)

      # …the topology resolver does not.
      assert Topology.workspace_root(inner) == Path.expand(root)
    end

    test "enclosing_roots/1 lists inner-first", %{root: root} do
      inner = Path.join(root, "miosa-compute")
      roots = Topology.enclosing_roots(inner)

      assert Path.expand(inner) in roots
      assert Path.expand(root) in roots

      assert Enum.find_index(roots, &(&1 == Path.expand(inner))) <
               Enum.find_index(roots, &(&1 == Path.expand(root)))
    end

    test "submodule?/1 recognizes the declared submodule but not the nested repo", %{root: root} do
      assert Topology.submodule?(Path.join(root, "vendor/subm"))
      refute Topology.submodule?(Path.join(root, "miosa-compute"))
    end
  end

  describe "ContextDiscovery.search_dirs/1" do
    test "includes the constellation root when cwd is inside a nested repo", %{root: root} do
      inner = Path.join(root, "miosa-compute")
      dirs = ContextDiscovery.search_dirs(inner)

      assert Path.expand(inner) in dirs

      assert Path.expand(root) in dirs,
             "the enclosing constellation root must be searched — this is the bug"
    end

    test "the inner repo is searched first, so its own file still wins", %{root: root} do
      inner = Path.join(root, "miosa-compute")
      dirs = ContextDiscovery.search_dirs(inner)
      assert List.first(dirs) == Path.expand(inner)
    end
  end

  # ── Rendering ──────────────────────────────────────────────────────────

  describe "Render.table/2" do
    test "wide terminal gets all four columns", %{root: root} do
      table = Render.table(Topology.detect(root), width: 120)

      assert table =~ "| Component | Type | Stack | Role |"
      assert table =~ "miosa-compute"
      assert table =~ "nested repo"
      assert table =~ "submodule"
    end

    test "medium width drops Stack", %{root: root} do
      table = Render.table(Topology.detect(root), width: 70)
      assert table =~ "| Component | Type | Role |"
      refute table =~ "Stack"
    end

    test "narrow width keeps only Component and Role", %{root: root} do
      table = Render.table(Topology.detect(root), width: 55)
      assert table =~ "| Component | Role |"
    end

    test "below the table floor it degrades to a list with no pipes", %{root: root} do
      out = Render.table(Topology.detect(root), width: 30)
      refute out =~ "|"
      assert out =~ "miosa-compute"
    end

    test "cell contents containing a pipe are escaped" do
      assert Render.markdown_table(["A"], [["x|y"]]) =~ "x\\|y"
    end
  end

  describe "Render.tree/2" do
    test "nests components under their parent and tags the git kind", %{root: root} do
      tree = Render.tree(Topology.detect(root), width: 120)

      assert tree =~ "├──" or tree =~ "└──"
      assert tree =~ "miosa-compute/"
      assert tree =~ "[nested repo]"
      assert tree =~ "[submodule]"
      # `apps/alpha` is rendered as a child of `apps`… but `apps` is not itself a
      # component, so alpha appears at the top level with its basename.
      assert tree =~ "alpha/"
    end

    test "narrow width sheds detail before it wraps", %{root: root} do
      tree = Render.tree(Topology.detect(root), width: 28)
      longest = tree |> String.split("\n") |> Enum.map(&String.length/1) |> Enum.max()
      assert longest <= 40
    end
  end

  describe "Render.report/2" do
    test "includes header, workspace declarations, table and tree", %{root: root} do
      out = Render.report(Topology.detect(root), width: 120)

      assert out =~ "## Workspace map"
      assert out =~ "Elixir umbrella"
      assert out =~ "pnpm workspace"
      assert out =~ "| Component |"
      assert out =~ "**Tree**"
    end

    test "an empty workspace renders without crashing" do
      dir = tmp("empty")
      on_exit(fn -> File.rm_rf(dir) end)
      assert Render.report(Topology.detect(dir), width: 80) =~ "no components detected"
    end
  end

  # ── Tool surface ───────────────────────────────────────────────────────

  describe "workspace_map tool" do
    alias OptimalSystemAgent.Tools.Builtins.WorkspaceMap

    test "is registered under a stable name" do
      assert WorkspaceMap.name() == "workspace_map"
      assert WorkspaceMap.safety() == :read_only
      assert WorkspaceMap.available?()
    end

    test "declares an object schema with no required args" do
      params = WorkspaceMap.parameters()
      assert params["type"] == "object"
      assert params["required"] == []
      assert Map.has_key?(params["properties"], "path")
      assert Map.has_key?(params["properties"], "format")
    end

    test "description tells the model when NOT to use it" do
      d = WorkspaceMap.description()
      assert d =~ "dir_list"
      assert d =~ "file_glob"
      assert d =~ "file_grep"
    end

    test "executes against an explicit path and returns metadata", %{root: root} do
      assert {:ok, output, meta} = WorkspaceMap.execute(%{"path" => root})

      assert output =~ "miosa-compute"
      assert meta.root == Path.expand(root)
      assert meta.component_count > 0
      assert :elixir_umbrella in meta.workspaces
    end

    test "format: table returns only the table", %{root: root} do
      assert {:ok, output, _} = WorkspaceMap.execute(%{"path" => root, "format" => "table"})
      assert output =~ "| Component |"
      refute output =~ "## Workspace map"
    end

    test "format: tree returns only the tree", %{root: root} do
      assert {:ok, output, _} = WorkspaceMap.execute(%{"path" => root, "format" => "tree"})
      assert output =~ "└──" or output =~ "├──"
      refute output =~ "| Component |"
    end

    test "a non-directory path is an error, not a crash", %{root: root} do
      assert {:error, msg} = WorkspaceMap.execute(%{"path" => Path.join(root, "mix.exs")})
      assert msg =~ "not a directory"
    end
  end

  # ── Fixture ────────────────────────────────────────────────────────────

  defp component(root, path) do
    root
    |> Topology.detect()
    |> Map.fetch!(:components)
    |> Enum.find(&(&1.path == path)) ||
      flunk("no component at #{path}")
  end

  defp component_cached(root, path) do
    root
    |> Topology.get()
    |> Map.fetch!(:components)
    |> Enum.find(&(&1.path == path)) ||
      flunk("no component at #{path}")
  end

  defp tmp(name) do
    dir = Path.join(System.tmp_dir!(), "osa_topo_#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp write(root, rel, body) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  # File.stat mtime has 1-second resolution, so a rewrite inside the same second
  # is invisible to the fingerprint. Push mtime forward explicitly.
  defp bump_mtime(path) do
    %File.Stat{mtime: mtime} = File.stat!(path)
    File.touch!(path, add_second(mtime))
  end

  defp add_second({{y, mo, d}, {h, mi, s}}) do
    {{y, mo, d}, {h, mi, s}}
    |> :calendar.datetime_to_gregorian_seconds()
    |> Kernel.+(5)
    |> :calendar.gregorian_seconds_to_datetime()
  end

  defp git(args, cwd) do
    System.cmd("git", args, cd: cwd, stderr_to_stdout: true, env: git_env())
  end

  # Isolate from the developer's own git config (hooks, templates, signing).
  defp git_env do
    [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_AUTHOR_NAME", "osa-test"},
      {"GIT_AUTHOR_EMAIL", "osa@test.invalid"},
      {"GIT_COMMITTER_NAME", "osa-test"},
      {"GIT_COMMITTER_EMAIL", "osa@test.invalid"}
    ]
  end

  defp init_repo(dir) do
    File.mkdir_p!(dir)
    {_, 0} = git(["-c", "init.defaultBranch=main", "init", "-q", "."], dir)
    dir
  end

  defp commit_all(dir, msg) do
    {_, 0} = git(["add", "-A"], dir)
    {_, _} = git(["commit", "-q", "-m", msg], dir)
    dir
  end

  @doc false
  # Builds the constellation:
  #
  #   root/                  git repo + Elixir umbrella + pnpm workspace
  #     apps/alpha           umbrella member, Elixir app
  #     apps/beta            umbrella member, Elixir library
  #     web/ui               pnpm member, React app
  #     web/core             pnpm member, JS library
  #     miosa-compute/       NESTED INDEPENDENT REPO (Phoenix app)
  #     vendor/subm          SUBMODULE (Go app)
  #     sdks/python          plain dir, Python SDK
  #     infra/tf             plain dir, Terraform
  #     docs/                plain dir, docs
  #     generated/           gitignored — must not appear
  #     node_modules, _build, target — skipped
  defp build_fixture(root) do
    submodule_src = root <> "_subsrc"

    # Start from nothing. `System.unique_integer/1` is unique only WITHIN a VM
    # and restarts low on every boot, so `osa_topo_25` is handed out again by
    # the next `mix test` — and when a previous run left that directory behind,
    # `git submodule add … vendor/subm` fails with
    # `fatal: 'vendor/subm' already exists in the index` (exit 128), which
    # raises inside `setup` and fails the whole module.
    #
    # The failure is SELF-PERPETUATING, which is why 34 `osa_topo_*` trees were
    # on disk before this line existed: the `on_exit` that removes `root` is
    # registered by the caller only AFTER `build_fixture/1` returns, so a
    # fixture that raises halfway leaves its half-built tree behind to collide
    # again on the next run.
    _ = File.rm_rf(root)
    _ = File.rm_rf(submodule_src)

    init_repo(root)

    write(root, ".gitignore", "generated/\n")
    write(root, "AGENTS.md", "constellation root instructions\n")

    write(root, "mix.exs", """
    defmodule Constellation.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0"]
    end
    """)

    write(root, "pnpm-workspace.yaml", """
    packages:
      - "web/*"
    """)

    # ── Elixir umbrella members ──
    write(root, "apps/alpha/mix.exs", """
    defmodule Alpha.MixProject do
      use Mix.Project
      def project, do: [app: :alpha, version: "0.1.0"]
      def application, do: [mod: {Alpha.Application, []}]
    end
    """)

    write(root, "apps/beta/mix.exs", """
    defmodule Beta.MixProject do
      use Mix.Project
      def project, do: [app: :beta, version: "0.1.0"]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    # ── pnpm members ──
    write(
      root,
      "web/ui/package.json",
      ~s({"name":"@c/ui","dependencies":{"react":"19"},"scripts":{"start":"vite"}})
    )

    write(root, "web/core/package.json", ~s({"name":"@c/core","main":"index.js"}))
    write(root, "web/ui/node_modules/junk/package.json", ~s({"name":"junk"}))

    # ── SDK / infra / docs ──
    write(
      root,
      "sdks/python/pyproject.toml",
      "[project]\nname = \"constellation-sdk\"\ndependencies = [\"httpx\"]\n"
    )

    write(root, "infra/tf/main.tf", "resource \"null_resource\" \"x\" {}\n")
    write(root, "docs/overview.md", "# Overview\n")

    # ── noise that must be skipped ──
    write(root, "_build/dev/lib/alpha/x.beam", "")
    write(root, "target/debug/x", "")
    write(root, "generated/thing/go.mod", "module example.com/generated\n")

    commit_all(root, "root")

    # ── nested INDEPENDENT repo (never added as a submodule) ──
    compute = Path.join(root, "miosa-compute")
    init_repo(compute)

    write(compute, "mix.exs", """
    defmodule MiosaCompute.MixProject do
      use Mix.Project
      def project, do: [app: :miosa_compute, version: "0.1.0"]
      def application, do: [mod: {MiosaCompute.Application, []}]
      defp deps, do: [{:phoenix, "~> 1.7"}]
    end
    """)

    write(compute, "AGENTS.md", "compute-specific instructions\n")
    commit_all(compute, "compute")

    # ── real submodule ──
    init_repo(submodule_src)
    write(submodule_src, "go.mod", "module example.com/subm\n\ngo 1.22\n")
    write(submodule_src, "cmd/subm/main.go", "package main\n\nfunc main() {}\n")
    commit_all(submodule_src, "subm")
    on_exit(fn -> File.rm_rf(submodule_src) end)

    {_, 0} =
      git(
        [
          "-c",
          "protocol.file.allow=always",
          "submodule",
          "add",
          "-q",
          submodule_src,
          "vendor/subm"
        ],
        root
      )

    commit_all(root, "add submodule")
    root
  end
end
