defmodule OptimalSystemAgent.Agents.RegistryTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agents.Registry

  test "loads Claude-style frontmatter aliases" do
    root = tmp_dir()
    agents_dir = Path.join([root, ".claude", "agents"])
    File.mkdir_p!(agents_dir)

    agent_path = Path.join(agents_dir, "verifier.md")

    File.write!(agent_path, """
    ---
    name: verifier
    description: Verify command evidence
    tools: ["file_read", "shell_execute"]
    disallowedTools: ["file_write"]
    maxTurns: 4
    permissionMode: plan
    model: claude-sonnet-4-5
    background: true
    isolation: worktree
    skills: ["testing"]
    ---
    Read-only verification prompt.
    """)

    agents = Registry.load_from_paths([{:project_claude, agents_dir}])

    assert %{
             name: "verifier",
             description: "Verify command evidence",
             tools_allowed: ["file_read", "shell_execute"],
             tools_blocked: ["file_write"],
             max_iterations: 4,
             permission_tier: :read_only,
             model: "claude-sonnet-4-5",
             background: true,
             isolation: :worktree,
             skills: ["testing"],
             system_prompt: "Read-only verification prompt.",
             source: :project_claude
           } = agents["verifier"]
  end

  test "later sources override earlier sources" do
    built_in = tmp_dir()
    project = tmp_dir()
    File.mkdir_p!(built_in)
    File.mkdir_p!(project)

    File.write!(Path.join(built_in, "explorer.md"), """
    ---
    name: explorer
    description: Built-in explorer
    ---
    Built-in prompt.
    """)

    File.write!(Path.join(project, "explorer.md"), """
    ---
    name: explorer
    description: Project explorer
    tools: file_read,file_grep
    ---
    Project prompt.
    """)

    agents = Registry.load_from_paths([{:built_in, built_in}, {:project_osa, project}])

    assert agents["explorer"].description == "Project explorer"
    assert agents["explorer"].tools_allowed == ["file_read", "file_grep"]
    assert agents["explorer"].system_prompt == "Project prompt."
    assert agents["explorer"].source == :project_osa
  end

  test "discovers project claude and osa agent directories from cwd to repo root" do
    root = tmp_dir()
    nested = Path.join([root, "apps", "osa"])
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join([root, ".claude", "agents"]))
    File.mkdir_p!(Path.join([nested, ".osa", "agents"]))

    dirs = Registry.discover_agent_dirs(nested)

    assert {:project_claude, Path.join([root, ".claude", "agents"])} in dirs
    assert {:project_osa, Path.join([nested, ".osa", "agents"])} in dirs
  end

  test "built-in verifier agent has read-only verdict contract" do
    agents = Registry.load_from_paths([{:built_in, Path.expand("../../priv/agents", __DIR__)}])

    assert %{
             permission_tier: :read_only,
             max_iterations: 4,
             tools_allowed: tools,
             system_prompt: prompt
           } = agents["verifier"]

    assert "file_read" in tools
    assert prompt =~ "VERDICT: PASS | FAIL | UNKNOWN"
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "osa_agent_registry_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
