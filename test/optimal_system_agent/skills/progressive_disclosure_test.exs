defmodule OptimalSystemAgent.Skills.ProgressiveDisclosureTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.SkillView
  alias OptimalSystemAgent.Tools.Registry
  alias OptimalSystemAgent.Tools.Registry.SkillLoader

  @skills_key {Registry, :skills}

  setup do
    old_skills = :persistent_term.get(@skills_key, %{})
    old_dir = Application.get_env(:optimal_system_agent, :skills_dir)

    root =
      Path.join(System.tmp_dir!(), "osa-progressive-skill-#{System.unique_integer([:positive])}")

    skill_dir = Path.join([root, "skills", "debugging"])
    File.mkdir_p!(skill_dir)

    path = Path.join(skill_dir, "SKILL.md")

    File.write!(
      path,
      """
      ---
      name: debugging
      description: Diagnose hard bugs from reproduction to regression test
      ---

      REPRODUCE-FIRST-SENTINEL
      """
    )

    Application.put_env(:optimal_system_agent, :skills_dir, Path.join(root, "skills"))

    skill = %{
      name: "debugging",
      description: "Diagnose hard bugs from reproduction to regression test",
      triggers: [],
      tools: [],
      priority: 5,
      paths: nil,
      scope: :user,
      path: path
    }

    :persistent_term.put(@skills_key, %{"debugging" => skill})

    on_exit(fn ->
      :persistent_term.put(@skills_key, old_skills)

      if old_dir,
        do: Application.put_env(:optimal_system_agent, :skills_dir, old_dir),
        else: Application.delete_env(:optimal_system_agent, :skills_dir)

      File.rm_rf!(root)
    end)

    :ok
  end

  test "the always-on catalog contains metadata but not the skill body" do
    catalog = Registry.active_skills_context("please diagnose this bug")

    assert catalog =~ "debugging"
    assert catalog =~ "call `skill_view`"
    refute catalog =~ "REPRODUCE-FIRST-SENTINEL"
    refute catalog =~ "Active Skill"
  end

  test "message-aware catalog ranks relevant skills ahead of a large library" do
    debugging = :persistent_term.get(@skills_key)["debugging"]

    irrelevant =
      for i <- 1..80, into: %{} do
        name = "aaa-unrelated-#{String.pad_leading(Integer.to_string(i), 3, "0")}"

        {name,
         %{
           debugging
           | name: name,
             description: "Prepare an unrelated weekly calendar summary"
         }}
      end

    :persistent_term.put(@skills_key, Map.put(irrelevant, "debugging", debugging))

    catalog = Registry.active_skills_context("diagnose a hard software bug")

    assert catalog =~ "**debugging**"
    assert catalog =~ "If no listed skill clearly fits, call `list_skills`"
    assert length(String.split(catalog, "\n")) < 40
  end

  test "catalog tells every agent how to search when the shortlist has no match" do
    catalog = Registry.active_skills_context("compose a baroque symphony")

    assert catalog =~ "If no listed skill clearly fits, call `list_skills`"
  end

  test "skill_view loads the selected body into the owning agent context" do
    assert {:ok, loaded} = SkillView.execute(%{"name" => "debugging"})
    assert loaded =~ "# Active Skill: debugging"
    assert loaded =~ "REPRODUCE-FIRST-SENTINEL"
  end

  test "Codex user skills are a configured discovery root" do
    assert Path.expand("~/.codex/skills") in SkillLoader.roots(File.cwd!())
  end

  test "a clean OSA package contains the native engineering core without external installs" do
    bundled = Registry.load_skill_definitions()
    names = MapSet.new(bundled, & &1.name)

    for expected <- ~w(
          diagnosing-bugs
          test-driven-development
          implementation
          frontend-quality
          security-audit
          skill-authoring
        ) do
      assert MapSet.member?(names, expected), "missing bundled skill #{expected}"
    end
  end
end
