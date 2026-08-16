defmodule OptimalSystemAgent.Skills.ValidatorTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Skills.Lint
  alias OptimalSystemAgent.Skills.Ranker
  alias OptimalSystemAgent.Skills.Validator
  alias OptimalSystemAgent.Tools.Registry.SkillLoader

  @good """
  ---
  name: db-migrate
  description: Run and roll back Ecto migrations safely against a live database, including the pre-flight backup step.
  triggers:
    - migration
    - ecto migrate
  priority: 2
  tools:
    - shell_execute
  ---

  ## Instructions

  1. Take a backup with `pg_dump`.
  2. Run `mix ecto.migrate`.
  3. Verify the schema version, then release the lock.
  """

  defp write!(dir, name, content) do
    path = Path.join([dir, name, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp rules(findings), do: findings |> Enum.map(& &1.rule) |> Enum.sort()

  setup do
    dir =
      Path.join(System.tmp_dir!(), "osa-skill-validator-#{System.unique_integer([:positive])}")

    # Project-scoped skills are workspace-supplied config and stay inert until
    # trust is accepted (Workspace.ProjectResource). These tests exercise
    # DISCOVERY semantics, not the trust gate, so the fixture repo is trusted
    # explicitly — see test/security/untrusted_project_resources_test.exs for
    # what happens when it is not.
    OptimalSystemAgent.Workspace.Trust.accept(dir)

    File.mkdir_p!(dir)

    on_exit(fn ->
      OptimalSystemAgent.Workspace.Trust.forget(dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  describe "a well-formed skill" do
    test "produces no findings", %{dir: dir} do
      path = write!(dir, "db-migrate", @good)
      assert Validator.validate_file(path) == []
    end
  end

  describe "the silent-fallback failures" do
    test "no frontmatter at all is an error naming the directory fallback", %{dir: dir} do
      path = write!(dir, "note-taker", "Just some prose, no header.\n")

      assert [f] = Validator.validate_file(path)
      assert f.severity == :error
      assert f.rule == :frontmatter_missing
      assert f.message =~ "named after its directory"
      assert f.message =~ "Fix:"
    end

    test "unterminated frontmatter is reported, not silently ignored", %{dir: dir} do
      path = write!(dir, "half-open", "---\nname: half-open\ndescription: nope\n")

      assert [f] = Validator.validate_file(path)
      assert f.rule == :frontmatter_unterminated
      assert f.message =~ "closing `---`"
    end

    test "invalid YAML is reported with a fix", %{dir: dir} do
      path = write!(dir, "bad-yaml", "---\nname: x\n\tdescription: tabbed\n---\n\nbody\n")

      findings = Validator.validate_file(path)
      assert :frontmatter_invalid_yaml in rules(findings)
    end

    test "frontmatter past the loader's bounded read window is an error", %{dir: dir} do
      filler = String.duplicate("x", 5_000)

      content = """
      ---
      name: fat-header
      description: A skill whose frontmatter is far too large for the bounded discovery read.
      notes: #{filler}
      ---

      ## Instructions

      Do the thing, then verify the thing was done correctly.
      """

      path = write!(dir, "fat-header", content)
      findings = Validator.validate_file(path)

      assert :frontmatter_too_large in rules(findings)

      msg = Enum.find(findings, &(&1.rule == :frontmatter_too_large)).message
      assert msg =~ "4096-byte"
      assert msg =~ "Fix:"
    end
  end

  describe "field rules" do
    test "a missing name is an error that suggests the typo'd key", %{dir: dir} do
      content = """
      ---
      nme: db-migrate
      description: Run and roll back Ecto migrations safely against a live database.
      ---

      ## Instructions

      Take a backup, then migrate, then verify the schema version.
      """

      path = write!(dir, "db-migrate", content)
      findings = Validator.validate_file(path)

      assert :name_missing in rules(findings)
      msg = Enum.find(findings, &(&1.rule == :name_missing)).message
      assert msg =~ "did you mean `name:`"
      assert msg =~ "Fix: add `name: db-migrate`"
    end

    test "a typo'd description key yields BOTH a missing description and an unknown key",
         %{dir: dir} do
      content = """
      ---
      name: db-migrate
      descrption: Run and roll back Ecto migrations safely against a live database.
      ---

      ## Instructions

      Take a backup, then migrate, then verify the schema version.
      """

      path = write!(dir, "db-migrate", content)
      findings = Validator.validate_file(path)

      assert :description_missing in rules(findings)
      assert :unknown_frontmatter_key in rules(findings)

      unknown = Enum.find(findings, &(&1.rule == :unknown_frontmatter_key))
      assert unknown.message =~ "did you mean `description:`"
    end

    test "a non-slug name is an error offering the slugified form", %{dir: dir} do
      content = String.replace(@good, "name: db-migrate", "name: DB Migrate!")
      path = write!(dir, "db-migrate", content)

      findings = Validator.validate_file(path)
      assert :name_format in rules(findings)
      assert Enum.find(findings, &(&1.rule == :name_format)).message =~ "`db-migrate`"
    end

    test "name/directory mismatch is a warning, not an error", %{dir: dir} do
      content = String.replace(@good, "name: db-migrate", "name: migrate-db")
      path = write!(dir, "db-migrate", content)

      findings = Validator.validate_file(path)
      assert :name_directory_mismatch in rules(findings)
      refute Validator.errors?(findings)
    end

    test "an over-long description is an error", %{dir: dir} do
      long = String.duplicate("a", 1_100)
      content = String.replace(@good, ~r/description: .*/, "description: #{long}")
      path = write!(dir, "db-migrate", content)

      findings = Validator.validate_file(path)
      assert :description_too_long in rules(findings)
      assert Validator.errors?(findings)
    end

    test "a thin description is a warning", %{dir: dir} do
      content = String.replace(@good, ~r/description: .*/, "description: migrate")
      path = write!(dir, "db-migrate", content)

      findings = Validator.validate_file(path)
      assert :description_too_short in rules(findings)
      refute Validator.errors?(findings)
    end

    test "an empty body is an error", %{dir: dir} do
      content = """
      ---
      name: empty
      description: A skill declared with a proper description but no instruction body at all.
      ---
      """

      path = write!(dir, "empty", content)
      assert :body_missing in rules(Validator.validate_file(path))
    end

    test "a mapping-shaped tools key is a warning naming the consequence", %{dir: dir} do
      content = """
      ---
      name: shaped
      description: A skill whose tools key uses a mapping instead of the list the loader reads.
      tools:
        shell: true
      ---

      ## Instructions

      Take a backup, then migrate, then verify the schema version afterwards.
      """

      path = write!(dir, "shaped", content)
      findings = Validator.validate_file(path)

      assert :tools_bad_shape in rules(findings)
      assert Enum.find(findings, &(&1.rule == :tools_bad_shape)).message =~ "runs unrestricted"
    end

    test "an unrecognised priority is a warning", %{dir: dir} do
      content = String.replace(@good, "priority: 2", "priority: urgent")
      path = write!(dir, "db-migrate", content)

      assert :priority_invalid in rules(Validator.validate_file(path))
    end
  end

  describe "every message is actionable" do
    test "all findings across every failure mode name a fix", %{dir: dir} do
      write!(dir, "a", "no header at all\n")
      write!(dir, "b", "---\nname: b\n")
      write!(dir, "c", "---\nnme: c\ndescrption: x\n---\n")
      write!(dir, "d", String.replace(@good, "name: db-migrate", "name: Bad Name"))

      %{findings: findings} = Lint.run(roots: [dir], include_bundled: false)

      assert findings != []

      for f <- findings do
        assert f.message =~ "Fix:", "finding #{f.rule} has no fix instruction: #{f.message}"
        assert String.length(f.message) > 40
      end
    end
  end

  describe "measured impact: a typo'd header makes a skill unrankable" do
    setup %{dir: dir} do
      root = Path.join(dir, ".osa/skills")

      broken = """
      ---
      name: db-migrate
      descrption: Run and roll back Ecto migrations safely against a live database, including backups.
      ---

      ## Instructions

      Take a backup, then migrate, then verify the schema version afterwards.
      """

      write!(root, "db-migrate", broken)
      {:ok, root: root, broken: broken}
    end

    test "the loader surfaces it with an empty description and the ranker scores it 0.0",
         %{dir: dir, root: root} do
      entry =
        SkillLoader.load_skills(cwd: dir)
        |> Map.fetch!("db-migrate")

      # The loader is happy: it parsed the frontmatter and built an entry.
      assert entry.description == ""

      # ...but the ranker has nothing to match a real task against.
      assert Ranker.relevance(entry.description, "roll back an ecto migration") == 0.0

      # The validator is the only thing that tells the author why.
      findings = Validator.validate_file(entry.path)
      assert :description_missing in rules(findings)

      # After applying the fix the validator names, the same query ranks it.
      fixed = File.read!(entry.path) |> String.replace("descrption:", "description:")
      File.write!(entry.path, fixed)

      fixed_entry = SkillLoader.load_skills(cwd: dir) |> Map.fetch!("db-migrate")
      assert Ranker.relevance(fixed_entry.description, "roll back an ecto migration") > 0.0
      assert Validator.validate_file(fixed_entry.path) == []

      _ = root
    end
  end

  describe "lint" do
    test "scans explicit roots and counts severities", %{dir: dir} do
      write!(dir, "ok", @good |> String.replace("name: db-migrate", "name: ok"))
      write!(dir, "broken", "no header\n")

      report = Lint.run(roots: [dir], include_bundled: false)

      assert length(report.scanned) == 2
      assert report.errors >= 1
      assert Lint.format(report) =~ "error(s)"
    end

    test "a clean tree formats as a single clean line", %{dir: dir} do
      write!(dir, "db-migrate", @good)
      report = Lint.run(roots: [dir], include_bundled: false)

      assert report.findings == []
      assert Lint.format(report) =~ "no issues"
    end

    test "finds a malformed skill that scope precedence would hide from the loader",
         %{dir: dir} do
      # Two scopes declare `db-migrate`; the local one wins in the loaded map,
      # so the broken user-scope copy is invisible to any entry-based check.
      local = Path.join(dir, "local/.osa/skills")
      user = Path.join(dir, "user/.osa/skills")

      write!(local, "db-migrate", @good)
      write!(user, "db-migrate", "no header at all\n")

      report = Lint.run(roots: [local, user], include_bundled: false)

      assert length(report.scanned) == 2
      assert :frontmatter_missing in rules(report.findings)
    end
  end

  describe "check_entry/1 (discovery-path half)" do
    test "flags exactly the load-wrong failures on a loader entry", %{dir: dir} do
      root = Path.join(dir, ".osa/skills")
      write!(root, "note-taker", "just prose, no frontmatter here at all\n")

      entry = SkillLoader.load_skills(cwd: dir) |> Map.fetch!("note-taker")

      findings = Validator.check_entry(entry)
      assert findings != []
      assert Enum.all?(findings, &(&1.message =~ "Fix:"))
    end

    test "is silent for a well-formed entry", %{dir: dir} do
      root = Path.join(dir, ".osa/skills")
      write!(root, "db-migrate", @good)

      entry = SkillLoader.load_skills(cwd: dir) |> Map.fetch!("db-migrate")
      assert Validator.check_entry(entry) == []
    end
  end
end
