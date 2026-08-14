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

    # Project agent dirs are workspace-supplied config (their frontmatter can
    # declare `permission_tier: bypassPermissions`), so discovery is gated on
    # workspace trust. This test is about the ancestor WALK and precedence —
    # accept trust so it exercises that rather than the gate. The gate itself
    # is covered by test/security/untrusted_project_agents_test.exs.
    alias OptimalSystemAgent.Workspace.Trust
    Trust.accept(nested)
    on_exit(fn -> Trust.forget(nested) end)

    dirs = Registry.discover_agent_dirs(nested)

    assert {:project_claude, Path.join([root, ".claude", "agents"])} in dirs
    assert {:project_osa, Path.join([nested, ".osa", "agents"])} in dirs
  end

  test "parses when_to_use frontmatter (snake_case and camelCase)" do
    dir = tmp_dir()

    File.write!(Path.join(dir, "snake.md"), """
    ---
    name: snake
    description: Snake agent
    when_to_use: You need the snake path
    ---
    Snake prompt.
    """)

    File.write!(Path.join(dir, "camel.md"), """
    ---
    name: camel
    description: Camel agent
    whenToUse: You need the camel path
    ---
    Camel prompt.
    """)

    agents = Registry.load_from_paths([{:built_in, dir}])

    assert agents["snake"].when_to_use == "You need the snake path"
    assert agents["camel"].when_to_use == "You need the camel path"
  end

  test "ships canonical built-in agent types" do
    dir = Path.join([File.cwd!(), "priv", "agents"])
    agents = Registry.load_from_paths([{:built_in, dir}])

    for name <- ["general-purpose", "explore", "plan", "code-review"] do
      assert Map.has_key?(agents, name), "missing built-in agent type: #{name}"
    end

    # general-purpose has full tool access (nil allowlist) and is not read-only.
    assert agents["general-purpose"].tools_allowed == nil
    assert agents["general-purpose"].permission_tier == :subagent

    # explore / plan / code-review are read-only.
    assert agents["explore"].permission_tier == :read_only
    assert agents["plan"].permission_tier == :read_only
    assert agents["code-review"].permission_tier == :read_only

    # explore targets a cheap (utility) tier; each ships a when_to_use hint.
    assert agents["explore"].tier == :utility
    assert agents["plan"].when_to_use != ""
  end

  defp tmp_dir do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    dir = Path.join(System.tmp_dir!(), "osa_agent_registry_#{suffix}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
