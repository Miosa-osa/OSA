defmodule OptimalSystemAgent.Skills.FrontmatterBomTest do
  @moduledoc """
  Five near-identical frontmatter parsers all matched on `["", frontmatter,
  body]`, so a UTF-8 BOM — which makes the head `"﻿"` instead of `""` —
  silently sent every one of them down its no-frontmatter branch:

    * a skill was renamed to its directory, described by the first 100 bytes of
      raw YAML, and lost `triggers:`, `tools:` and its `paths:` withholding gate
    * the skill's raw YAML leaked into the model's instructions
    * a slash command lost `name:`/`description:` and became a whole-file template
    * a SUBAGENT fell to `tools_allowed: nil` / `tools_blocked: []` with its
      entire file, frontmatter included, as `system_prompt` — an authored tool
      restriction discarded without a word
    * the linter reported `:frontmatter_missing` on a file starting with `---`
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Skills.Frontmatter
  alias OptimalSystemAgent.Skills.Validator
  alias OptimalSystemAgent.Tools.Registry.CommandLoader
  alias OptimalSystemAgent.Tools.Registry.SkillLoader

  @bom "﻿"

  setup do
    root = Path.join(System.tmp_dir!(), "osa_fm_bom_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))

    prev = Application.get_env(:optimal_system_agent, :skills_dir)
    Application.put_env(:optimal_system_agent, :skills_dir, Path.join(root, "user-skills"))

    on_exit(fn ->
      File.rm_rf(root)

      if prev,
        do: Application.put_env(:optimal_system_agent, :skills_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :skills_dir)
    end)

    {:ok, root: root}
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "the shared parser" do
    test "strips a BOM before splitting" do
      assert {:ok, meta, body} = Frontmatter.parse(@bom <> "---\nname: x\n---\n\nbody text\n")
      assert meta["name"] == "x"
      assert String.trim(body) == "body text"
    end

    test "distinguishes 'no frontmatter' from 'frontmatter that will not close'" do
      assert {:error, :missing} = Frontmatter.parse("just a markdown file\n")
      assert {:error, :unterminated} = Frontmatter.parse("---\nname: x\nno closing delimiter\n")
    end

    test "body/1 never returns the BOM or the frontmatter" do
      assert Frontmatter.body(@bom <> "---\nname: x\n---\n\nINSTRUCTIONS\n") == "INSTRUCTIONS"
      refute String.contains?(Frontmatter.body(@bom <> "plain\n"), @bom)
    end
  end

  describe "SkillLoader" do
    test "a BOM'd SKILL.md keeps its name, triggers and paths gate", %{root: root} do
      write!(
        Path.join([root, ".osa", "skills", "some-dir", "SKILL.md"]),
        @bom <>
          """
          ---
          name: bom-skill
          description: A real description
          triggers:
            - alpha
          paths:
            - "**/*.rs"
          ---

          THE INSTRUCTIONS
          """
      )

      skills = SkillLoader.load_skills(cwd: root)

      entry =
        skills["bom-skill"] ||
          flunk("BOM'd skill was renamed to its directory: #{inspect(Map.keys(skills))}")

      assert entry.description == "A real description"
      assert entry.triggers == ["alpha"]
      assert entry.paths == ["**/*.rs"], "the `paths:` withholding gate was dropped"

      # And it stays withheld until a matching file is touched.
      refute Enum.any?(SkillLoader.list_for_model(skills, []), &(&1.name == "bom-skill"))
      assert Enum.any?(SkillLoader.list_for_model(skills, ["a/b.rs"]), &(&1.name == "bom-skill"))
    end

    test "load_body/1 does not leak raw YAML into the instructions", %{root: root} do
      path =
        write!(
          Path.join([root, ".osa", "skills", "leaky", "SKILL.md"]),
          @bom <> "---\nname: leaky\ndescription: d\n---\n\nBODY ONLY\n"
        )

      assert {:ok, body} = SkillLoader.load_body(path)
      assert body == "BODY ONLY"
      refute String.contains?(body, "description:")
    end
  end

  describe "CommandLoader" do
    test "a BOM'd slash command keeps its name and description", %{root: root} do
      write!(
        Path.join([root, ".osa", "commands", "deploy.md"]),
        @bom <> "---\nname: shipit\ndescription: Ship the thing\n---\n\nTEMPLATE BODY\n"
      )

      Application.put_env(
        :optimal_system_agent,
        :commands_dir,
        Path.join([root, ".osa", "commands"])
      )

      on_exit(fn -> Application.delete_env(:optimal_system_agent, :commands_dir) end)

      cmds = CommandLoader.load_commands()

      cmd = cmds["shipit"] || flunk("BOM'd command lost its name: #{inspect(Map.keys(cmds))}")
      assert cmd.description == "Ship the thing"
      assert String.trim(cmd.template) == "TEMPLATE BODY"
    end
  end

  describe "Agents.Registry" do
    test "a BOM'd AGENT.md keeps its declared tool restrictions", %{root: root} do
      dir = Path.join(root, "agents")

      write!(
        Path.join(dir, "restricted.md"),
        @bom <>
          """
          ---
          name: restricted
          description: A locked-down agent
          tools_blocked:
            - shell_execute
          ---

          You may not run shell commands.
          """
      )

      agents = AgentRegistry.load_from_paths([{:user, dir}])
      agent = agents["restricted"] || flunk("agent missing: #{inspect(Map.keys(agents))}")

      assert agent.tools_blocked == ["shell_execute"],
             "an authored tool restriction was silently discarded"

      refute String.contains?(agent.system_prompt, "tools_blocked"),
             "raw frontmatter leaked into the subagent system prompt"
    end

    test "an agent whose frontmatter will not parse REFUSES to load rather than load unrestricted",
         %{root: root} do
      dir = Path.join(root, "agents")

      # Opens with `---`, declares a restriction, never closes the block.
      write!(
        Path.join(dir, "broken.md"),
        "---\nname: broken\ntools_blocked:\n  - shell_execute\n"
      )

      agents = AgentRegistry.load_from_paths([{:user, dir}])

      assert agents == %{},
             "a subagent whose tools_blocked cannot be read was loaded UNRESTRICTED: " <>
               inspect(agents)
    end

    test "a plain markdown agent with no frontmatter at all still loads", %{root: root} do
      dir = Path.join(root, "agents")
      write!(Path.join(dir, "plain.md"), "You are a helpful agent.\n")

      agents = AgentRegistry.load_from_paths([{:user, dir}])
      assert agents["plain"].system_prompt =~ "helpful agent"
    end
  end

  describe "Skills.Validator" do
    test "does not report :frontmatter_missing on a BOM'd file that starts with ---", %{
      root: root
    } do
      path =
        write!(
          Path.join([root, ".osa", "skills", "linted", "SKILL.md"]),
          @bom <> "---\nname: linted\ndescription: A described skill\n---\n\nBody here.\n"
        )

      findings = Validator.validate_file(path)

      refute Enum.any?(findings, &(&1.rule == :frontmatter_missing)),
             "the linter flagged a file that plainly starts with `---`: #{inspect(findings)}"
    end
  end
end
