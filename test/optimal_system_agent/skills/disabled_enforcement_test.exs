defmodule OptimalSystemAgent.Skills.DisabledEnforcementTest do
  @moduledoc """
  Disabled skills used to reach the model anyway, two independent ways.

  (a) The `.disabled` marker was enforced at a FLAT
      `<skills_dir>/<frontmatter-name>/` path while discovery globs
      `**/SKILL.md` across six roots and takes the name from frontmatter. A
      skill nested under a category directory, or whose frontmatter `name:`
      differs from its directory, or living in any scope other than the
      configured skills dir, could not be disabled at all.

  (b) Worse: `Tools.Registry.match_skill_triggers/1` filtered on trigger
      substrings only — no `.disabled` check and no `paths:` gate — and the
      caller injects the FULL instruction body for every match. A disabled
      skill's entire body was shipped to the provider on a trigger word.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Registry
  alias OptimalSystemAgent.Tools.Registry.SkillLoader

  @pt_key {Registry, :skills}

  setup do
    root = Path.join(System.tmp_dir!(), "osa_disabled_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))

    prev_dir = Application.get_env(:optimal_system_agent, :skills_dir)
    prev_skills = :persistent_term.get(@pt_key, %{})
    Application.put_env(:optimal_system_agent, :skills_dir, Path.join(root, "user-skills"))

    on_exit(fn ->
      File.rm_rf(root)
      :persistent_term.put(@pt_key, prev_skills)

      if prev_dir,
        do: Application.put_env(:optimal_system_agent, :skills_dir, prev_dir),
        else: Application.delete_env(:optimal_system_agent, :skills_dir)
    end)

    {:ok, root: root}
  end

  defp write_skill(dir, frontmatter, body \\ "THE FULL INSTRUCTION BODY") do
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, "---\n#{frontmatter}\n---\n\n#{body}\n")
    path
  end

  defp disable!(dir), do: File.write!(Path.join(dir, ".disabled"), "off")

  describe "(a) the marker works wherever the skill actually lives" do
    test "a NESTED skill can be disabled", %{root: root} do
      dir = Path.join([root, ".osa", "skills", "reasoning", "deep-think"])
      write_skill(dir, "name: deep-think\ndescription: d")

      skills = SkillLoader.load_skills(cwd: root)
      refute SkillLoader.disabled?(skills["deep-think"])

      disable!(dir)

      assert SkillLoader.disabled?(skills["deep-think"]),
             "a skill nested under a category directory could not be disabled"

      refute Map.has_key?(SkillLoader.reject_disabled(skills), "deep-think")
    end

    test "a skill whose frontmatter name differs from its directory can be disabled", %{
      root: root
    } do
      dir = Path.join([root, ".osa", "skills", "some-folder"])
      write_skill(dir, "name: totally-different\ndescription: d")

      skills = SkillLoader.load_skills(cwd: root)
      assert Map.has_key?(skills, "totally-different")

      disable!(dir)
      assert SkillLoader.disabled?(skills["totally-different"])
    end

    test "reject_disabled/1 keeps the shape it was given", %{root: root} do
      dir = Path.join([root, ".osa", "skills", "listed"])
      write_skill(dir, "name: listed\ndescription: d")

      skills = SkillLoader.load_skills(cwd: root)

      mine = fn s ->
        s |> Map.values() |> SkillLoader.reject_disabled() |> Enum.filter(&(&1.name == "listed"))
      end

      assert [%{name: "listed"}] = mine.(skills)

      disable!(dir)
      assert [] == mine.(skills)
    end
  end

  describe "(b) the trigger-injection path honours the same gates as the listing" do
    test "a DISABLED skill's body is not injected on a trigger word", %{root: root} do
      dir = Path.join([root, ".osa", "skills", "category", "secret"])
      write_skill(dir, "name: secret\ndescription: d\ntriggers:\n  - magicword")
      disable!(dir)

      :persistent_term.put(@pt_key, SkillLoader.load_skills(cwd: root))

      assert Registry.match_skill_triggers("please use the magicword now") == [],
             "a disabled skill matched a trigger — its full body would be sent to the provider"
    end

    test "a `paths:`-gated skill is not injected before a matching file is touched", %{
      root: root
    } do
      dir = Path.join([root, ".osa", "skills", "rusty"])

      write_skill(
        dir,
        "name: rusty\ndescription: d\ntriggers:\n  - magicword\npaths:\n  - \"**/*.rs\""
      )

      :persistent_term.put(@pt_key, SkillLoader.load_skills(cwd: root))

      assert Registry.match_skill_triggers("please use the magicword now") == [],
             "a paths-gated skill leaked its body before any matching file was touched"
    end

    test "an enabled, ungated skill still matches", %{root: root} do
      dir = Path.join([root, ".osa", "skills", "normal"])
      write_skill(dir, "name: normal\ndescription: d\ntriggers:\n  - magicword")

      :persistent_term.put(@pt_key, SkillLoader.load_skills(cwd: root))

      assert [{"normal", _}] = Registry.match_skill_triggers("say the magicword")
    end
  end

  describe "invoke-time path enforcement" do
    test "a repo-scoped skill is runnable, not advertised-then-refused", %{root: root} do
      dir = Path.join([root, ".claude", "skills", "compat"])
      path = write_skill(dir, "name: compat\ndescription: d")

      assert SkillLoader.within_roots?(path, root),
             "a .claude-compat skill is listed in the prompt but refused at invoke"
    end

    test "containment is a path-boundary test, not a prefix test", %{root: root} do
      skills_dir = Path.join(root, "user-skills")
      File.mkdir_p!(skills_dir)

      sneaky = Path.join(root, "user-skills-backup/evil/SKILL.md")
      File.mkdir_p!(Path.dirname(sneaky))
      File.write!(sneaky, "---\nname: evil\n---\n\nbody\n")

      refute SkillLoader.within_roots?(sneaky, root),
             "`<skills_dir>-backup/...` satisfied a String.starts_with? prefix test"
    end
  end
end
