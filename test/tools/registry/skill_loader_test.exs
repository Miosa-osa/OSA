defmodule OptimalSystemAgent.Tools.Registry.SkillLoaderTest do
  # async: false — mutates the global :skills_dir application env.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Registry.{SkillLoader, SkillTouch}

  setup do
    root = Path.join(System.tmp_dir!(), "osa_skill_loader_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    # A .git at the root makes ancestor discovery stop here (deterministic scope).
    File.mkdir_p!(Path.join(root, ".git"))

    prev = Application.get_env(:optimal_system_agent, :skills_dir)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:optimal_system_agent, :skills_dir, prev)
      else
        Application.delete_env(:optimal_system_agent, :skills_dir)
      end
    end)

    {:ok, root: root}
  end

  # Write a SKILL.md at <base>/<cfg_dir>/skills/<name>/SKILL.md and return its path.
  defp write_skill(base, cfg_dir, name, frontmatter, body) do
    dir = Path.join([base, cfg_dir, "skills", name])
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, "---\n#{frontmatter}\n---\n\n#{body}")
    path
  end

  describe "frontmatter-only listing (progressive disclosure)" do
    test "parses frontmatter without loading the body", %{root: root} do
      big_body = "SECRET_BODY_MARKER\n" <> String.duplicate("filler line\n", 2_000)

      write_skill(
        root,
        ".osa",
        "fm-only-skill",
        "name: fm-only-skill\ndescription: A frontmatter-only test\ntriggers:\n  - alpha\n  - beta",
        big_body
      )

      skills = SkillLoader.load_skills(cwd: root)
      entry = skills["fm-only-skill"]

      assert entry.name == "fm-only-skill"
      assert entry.description == "A frontmatter-only test"
      assert entry.triggers == ["alpha", "beta"]
      assert entry.scope == :local
      assert String.ends_with?(entry.path, "SKILL.md")

      # The body must NOT be part of the listing entry.
      refute Map.has_key?(entry, :instructions)
      refute entry |> inspect(limit: :infinity) |> String.contains?("SECRET_BODY_MARKER")
    end

    test "bounded read ignores a body larger than the frontmatter window", %{root: root} do
      # Body far exceeds the 4KB bounded read; frontmatter must still parse and
      # the (unbounded) huge body must never appear in the listing.
      huge = String.duplicate("x", 50_000)

      write_skill(
        root,
        ".osa",
        "bounded-skill",
        "name: bounded-skill\ndescription: bounded",
        huge
      )

      skills = SkillLoader.load_skills(cwd: root)
      assert %{description: "bounded"} = skills["bounded-skill"]
      refute Map.has_key?(skills["bounded-skill"], :instructions)
    end
  end

  describe "on-demand body loading" do
    test "load_skill_with_body/1 loads the body only when asked", %{root: root} do
      write_skill(
        root,
        ".osa",
        "lazy-body",
        "name: lazy-body\ndescription: lazy",
        "## Instructions\n\nDO_THE_THING with care."
      )

      skills = SkillLoader.load_skills(cwd: root)
      entry = skills["lazy-body"]
      refute Map.has_key?(entry, :instructions)

      assert {:ok, loaded} = SkillLoader.load_skill_with_body(entry)
      assert loaded.instructions =~ "DO_THE_THING with care."
      # Frontmatter is stripped from the loaded body.
      refute loaded.instructions =~ "name: lazy-body"
    end

    test "load_body/1 returns the body with frontmatter stripped", %{root: root} do
      path =
        write_skill(
          root,
          ".osa",
          "body-only",
          "name: body-only\ndescription: d",
          "BODY_CONTENT_HERE"
        )

      assert {:ok, body} = SkillLoader.load_body(path)
      assert body == "BODY_CONTENT_HERE"
    end

    test "load_body/1 errors on a missing path" do
      assert {:error, _} = SkillLoader.load_body("/nonexistent/SKILL.md")
      assert {:error, :no_path} = SkillLoader.load_body(nil)
    end
  end

  describe "paths-glob lazy surfacing" do
    test "a paths-gated skill is hidden until a matching path is touched", %{root: root} do
      write_skill(
        root,
        ".osa",
        "py-skill",
        "name: py-skill\ndescription: python helper\npaths:\n  - \"**/*.py\"",
        "python body"
      )

      write_skill(
        root,
        ".osa",
        "always-skill",
        "name: always-skill\ndescription: always on",
        "always body"
      )

      skills = SkillLoader.load_skills(cwd: root)

      # Non-gated skill always surfaces; gated skill hidden with no touches.
      names_none = SkillLoader.list_for_model(skills, []) |> Enum.map(& &1.name)
      assert "always-skill" in names_none
      refute "py-skill" in names_none

      # Touch an unrelated file: still hidden.
      names_txt = SkillLoader.list_for_model(skills, ["/proj/readme.txt"]) |> Enum.map(& &1.name)
      refute "py-skill" in names_txt

      # Touch a matching file: now surfaced.
      names_py = SkillLoader.list_for_model(skills, ["/proj/src/main.py"]) |> Enum.map(& &1.name)
      assert "py-skill" in names_py
      assert "always-skill" in names_py
    end

    test "surfaced?/2 honors glob semantics" do
      gated = %{name: "g", paths: ["lib/**/*.ex"]}
      assert SkillLoader.surfaced?(gated, ["/x/lib/foo/bar.ex"])
      refute SkillLoader.surfaced?(gated, ["/x/test/foo.ex"])
      refute SkillLoader.surfaced?(gated, [])

      assert SkillLoader.surfaced?(%{name: "n", paths: nil}, [])
      assert SkillLoader.surfaced?(%{name: "e", paths: []}, [])
    end

    test "path_matches_glob?/2" do
      assert SkillLoader.path_matches_glob?("/a/b/c.py", "**/*.py")
      assert SkillLoader.path_matches_glob?("main.py", "*.py")
      assert SkillLoader.path_matches_glob?("/a/lib/x.ex", "lib/*.ex")
      refute SkillLoader.path_matches_glob?("/a/lib/nested/x.ex", "lib/*.ex")
      refute SkillLoader.path_matches_glob?("/a/b/c.rb", "*.py")
    end

    test "SkillTouch records and lists per-session touched paths" do
      session = "sess-#{System.unique_integer([:positive])}"
      assert SkillTouch.list(session) == []

      :ok = SkillTouch.record(session, "/proj/a.py")
      :ok = SkillTouch.record(session, "/proj/b.py")
      # Duplicate is de-duplicated.
      :ok = SkillTouch.record(session, "/proj/a.py")

      touched = SkillTouch.list(session)
      assert Enum.sort(touched) == ["/proj/a.py", "/proj/b.py"]

      # Isolated per session.
      assert SkillTouch.list("other-#{System.unique_integer([:positive])}") == []

      :ok = SkillTouch.reset(session)
      assert SkillTouch.list(session) == []
    end
  end

  describe "scope precedence (lower wins)" do
    test "local overrides repo overrides user for the same name", %{root: root} do
      # cwd is a subdir; repo root (.git) is `root`.
      cwd = Path.join(root, "sub")
      File.mkdir_p!(cwd)

      user_dir = Path.join(root, "userskills")
      File.mkdir_p!(user_dir)
      Application.put_env(:optimal_system_agent, :skills_dir, user_dir)

      # user-scope copy
      File.mkdir_p!(Path.join([user_dir, "dup-skill"]))

      File.write!(
        Path.join([user_dir, "dup-skill", "SKILL.md"]),
        "---\nname: dup-skill\ndescription: from-user\n---\n\nuser body"
      )

      # repo-scope copy (at root/.osa/skills, an ancestor of cwd)
      write_skill(root, ".osa", "dup-skill", "name: dup-skill\ndescription: from-repo", "repo body")

      # local-scope copy (at cwd/.osa/skills)
      write_skill(cwd, ".osa", "dup-skill", "name: dup-skill\ndescription: from-local", "local body")

      skills = SkillLoader.load_skills(cwd: cwd)
      entry = skills["dup-skill"]

      assert entry.scope == :local
      assert entry.description == "from-local"
    end

    test "repo wins over user when there is no local copy", %{root: root} do
      cwd = Path.join(root, "sub")
      File.mkdir_p!(cwd)

      user_dir = Path.join(root, "userskills2")
      File.mkdir_p!(Path.join([user_dir, "repo-vs-user"]))
      Application.put_env(:optimal_system_agent, :skills_dir, user_dir)

      File.write!(
        Path.join([user_dir, "repo-vs-user", "SKILL.md"]),
        "---\nname: repo-vs-user\ndescription: from-user\n---\n\nuser body"
      )

      write_skill(root, ".osa", "repo-vs-user", "name: repo-vs-user\ndescription: from-repo", "r")

      skills = SkillLoader.load_skills(cwd: cwd)
      entry = skills["repo-vs-user"]

      assert entry.scope == :repo
      assert entry.description == "from-repo"
    end

    test "Claude-compatible .claude/skills directory is scanned", %{root: root} do
      write_skill(
        root,
        ".claude",
        "claude-skill",
        "name: claude-skill\ndescription: claude compat",
        "body"
      )

      skills = SkillLoader.load_skills(cwd: root)
      assert %{scope: :local, description: "claude compat"} = skills["claude-skill"]
    end

    test "vendor directories are not scanned", %{root: root} do
      # A SKILL.md buried under node_modules must be ignored.
      vendor =
        Path.join([root, ".osa", "skills", "node_modules", "pkg", "vendored"])

      File.mkdir_p!(vendor)

      File.write!(
        Path.join(vendor, "SKILL.md"),
        "---\nname: vendored-skill\ndescription: should-not-load\n---\n\nx"
      )

      skills = SkillLoader.load_skills(cwd: root)
      refute Map.has_key?(skills, "vendored-skill")
    end
  end
end
