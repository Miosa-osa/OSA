defmodule OptimalSystemAgent.Security.StoreIntegrityTest do
  @moduledoc """
  Regression tests for the destructive-path / store-integrity / secret-permission
  audit.

  Each test here corresponds to a way OSA could silently destroy user data or
  expose a credential. They are grouped by the defect, not by module, because
  several of the defects are the SAME defect appearing in different files.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP
  alias OptimalSystemAgent.Memory.SkillGenerator
  alias OptimalSystemAgent.System.JsonStore
  alias OptimalSystemAgent.Tools.Builtins.SkillManager

  @moduletag :security

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # ── 1. Path traversal in skill_manager ───────────────────────────────

  describe "skill_manager path containment" do
    setup do
      root = tmp_dir("skills_root")
      skills = Path.join(root, "skills")
      File.mkdir_p!(Path.join(skills, "real-skill"))
      File.write!(Path.join([skills, "real-skill", "SKILL.md"]), "hand written")

      # A sibling of the skills dir, standing in for everything else under
      # ~/.osa: sessions, transcripts, memory, credentials, config.
      File.mkdir_p!(Path.join(root, "sessions"))
      File.write!(Path.join([root, "sessions", "s1.jsonl"]), "precious")

      prev = Application.get_env(:optimal_system_agent, :skills_dir)
      Application.put_env(:optimal_system_agent, :skills_dir, skills)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :skills_dir, prev),
          else: Application.delete_env(:optimal_system_agent, :skills_dir)
      end)

      {:ok, root: root, skills: skills}
    end

    test "delete with name '..' does not escape the skills directory", ctx do
      assert {:error, msg} = SkillManager.execute(%{"action" => "delete", "name" => ".."})
      assert msg =~ "kebab-case" or msg =~ "escapes"

      # The whole ~/.osa equivalent must survive.
      assert File.exists?(Path.join([ctx.root, "sessions", "s1.jsonl"]))
      assert File.dir?(ctx.skills)
      assert File.exists?(Path.join([ctx.skills, "real-skill", "SKILL.md"]))
    end

    test "delete with name '.' does not wipe the skills tree", ctx do
      assert {:error, _} = SkillManager.execute(%{"action" => "delete", "name" => "."})
      assert File.exists?(Path.join([ctx.skills, "real-skill", "SKILL.md"]))
    end

    test "delete with an empty name is refused", ctx do
      assert {:error, _} = SkillManager.execute(%{"action" => "delete", "name" => ""})
      assert File.dir?(ctx.skills)
    end

    test "delete with a nested traversal is refused", ctx do
      assert {:error, _} =
               SkillManager.execute(%{"action" => "delete", "name" => "real-skill/../.."})

      assert File.exists?(Path.join([ctx.root, "sessions", "s1.jsonl"]))
    end

    test "delete with an absolute path is refused", ctx do
      assert {:error, _} = SkillManager.execute(%{"action" => "delete", "name" => ctx.root})
      assert File.exists?(Path.join([ctx.root, "sessions", "s1.jsonl"]))
    end

    test "disable with name '..' does not write outside the skills directory", ctx do
      assert {:error, _} = SkillManager.execute(%{"action" => "disable", "name" => ".."})
      refute File.exists?(Path.join(ctx.root, ".disabled"))
    end

    test "enable with name '..' does not remove a marker outside the skills directory", ctx do
      marker = Path.join(ctx.root, ".disabled")
      File.write!(marker, "outside")

      assert {:error, _} = SkillManager.execute(%{"action" => "enable", "name" => ".."})
      assert File.exists?(marker)
    end

    test "a legitimate delete still works", ctx do
      assert {:ok, _} = SkillManager.execute(%{"action" => "delete", "name" => "real-skill"})
      refute File.exists?(Path.join(ctx.skills, "real-skill"))
      assert File.dir?(ctx.skills)
    end

    test "a recursive-delete tool is classified as destructive, not auto-approvable" do
      assert SkillManager.safety() == :write_destructive
    end
  end

  # ── 3. Read-degrades-to-empty feeding a whole-file rewrite ───────────

  describe "JsonStore read-for-write contract" do
    test "missing file is a fresh start, not corruption" do
      dir = tmp_dir("jsonstore")
      assert JsonStore.read_map_for_write(Path.join(dir, "nope.json")) == {:ok, %{}}
    end

    test "empty file is a fresh start" do
      dir = tmp_dir("jsonstore")
      path = Path.join(dir, "empty.json")
      File.write!(path, "   \n")
      assert JsonStore.read_map_for_write(path) == {:ok, %{}}
    end

    test "unparseable file refuses rather than degrading to %{}" do
      dir = tmp_dir("jsonstore")
      path = Path.join(dir, "bad.json")
      File.write!(path, ~s({"a": 1,}))
      assert JsonStore.read_map_for_write(path) == {:error, :corrupt}
    end

    test "non-object top-level JSON refuses" do
      dir = tmp_dir("jsonstore")
      path = Path.join(dir, "arr.json")
      File.write!(path, "[1,2,3]")
      assert JsonStore.read_map_for_write(path) == {:error, :corrupt}
    end

    test "list read returns [] for a missing key but refuses a non-list one" do
      dir = tmp_dir("jsonstore")
      ok = Path.join(dir, "ok.json")
      File.write!(ok, ~s({"jobs": [1, 2]}))
      assert JsonStore.read_list_for_write(ok, "jobs") == {:ok, [1, 2]}
      assert JsonStore.read_list_for_write(ok, "triggers") == {:ok, []}

      bad = Path.join(dir, "bad.json")
      File.write!(bad, ~s({"jobs": "nope"}))
      assert JsonStore.read_list_for_write(bad, "jobs") == {:error, :corrupt}
    end
  end

  describe "cron/trigger store" do
    alias OptimalSystemAgent.Agent.Scheduler.Persistence

    setup do
      dir = tmp_dir("crons")
      prev = Application.get_env(:optimal_system_agent, :config_dir)
      Application.put_env(:optimal_system_agent, :config_dir, dir)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :config_dir, prev),
          else: Application.delete_env(:optimal_system_agent, :config_dir)
      end)

      {:ok, dir: dir}
    end

    test "adding a cron to a corrupt CRONS.json refuses instead of wiping it", ctx do
      path = Path.join(ctx.dir, "CRONS.json")
      # A real file with real jobs, plus one trailing comma.
      original = ~s({"jobs": [{"id": "a", "enabled": true}, {"id": "b", "enabled": true},]})
      File.write!(path, original)

      state = %{cron_jobs: [], triggers_raw: [], trigger_handlers: %{}}

      assert {:error, msg} =
               Persistence.update_crons(state, fn jobs -> jobs ++ [%{"id" => "new"}] end)

      assert msg =~ "Refusing"
      # The user's jobs are still on disk, recoverable.
      assert File.read!(path) == original
    end

    test "adding a cron to a valid CRONS.json preserves the existing jobs", ctx do
      path = Path.join(ctx.dir, "CRONS.json")
      File.write!(path, ~s({"jobs": [{"id": "a", "enabled": true}]}))

      # State claims no jobs — as it does after any boot-time parse failure.
      state = %{cron_jobs: [], triggers_raw: [], trigger_handlers: %{}}

      assert {:ok, _} =
               Persistence.update_crons(state, fn jobs ->
                 jobs ++ [%{"id" => "new", "enabled" => true}]
               end)

      assert {:ok, %{"jobs" => jobs}} = Jason.decode(File.read!(path))
      assert Enum.map(jobs, & &1["id"]) == ["a", "new"]
    end

    test "adding a trigger to a corrupt TRIGGERS.json refuses instead of wiping it", ctx do
      path = Path.join(ctx.dir, "TRIGGERS.json")
      original = ~s({"triggers": [{"id": "t1"},]})
      File.write!(path, original)

      state = %{cron_jobs: [], triggers_raw: [], trigger_handlers: %{}}

      assert {:error, msg} =
               Persistence.update_triggers(state, fn ts -> ts ++ [%{"id" => "t2"}] end)

      assert msg =~ "Refusing"
      assert File.read!(path) == original
    end
  end

  describe "MCP server store" do
    setup do
      dir = tmp_dir("mcp")
      prev = Application.get_env(:optimal_system_agent, :config_dir)
      Application.put_env(:optimal_system_agent, :config_dir, dir)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :config_dir, prev),
          else: Application.delete_env(:optimal_system_agent, :config_dir)
      end)

      {:ok, dir: dir}
    end

    test "add_server preserves every other configured server" do
      assert {:ok, path} = MCP.Config.add_server("one", %{"command" => "a"}, :user)
      assert {:ok, ^path} = MCP.Config.add_server("two", %{"command" => "b"}, :user)

      assert {:ok, %{"mcpServers" => servers}} = Jason.decode(File.read!(path))
      assert Map.keys(servers) |> Enum.sort() == ["one", "two"]
    end

    test "add_server refuses to overwrite an unreadable mcp.json" do
      assert {:ok, path} = MCP.Config.add_server("one", %{"command" => "a"}, :user)
      original = ~s({"mcpServers": {"one": {"command": "a"},}})
      File.write!(path, original)

      assert {:error, msg} = MCP.Config.add_server("two", %{"command" => "b"}, :user)
      assert msg =~ "Refusing"
      assert File.read!(path) == original
    end

    test "remove_server refuses to overwrite an unreadable mcp.json" do
      assert {:ok, path} = MCP.Config.add_server("one", %{"command" => "a"}, :user)
      original = ~s({"mcpServers": {"one": {"command": "a"},}})
      File.write!(path, original)

      assert {:error, msg} = MCP.Config.remove_server("one", :user)
      assert msg =~ "Refusing"
      assert File.read!(path) == original
    end
  end

  describe "permission rule store" do
    alias OptimalSystemAgent.Permissions

    setup do
      dir = tmp_dir("perms")
      path = Path.join(dir, "permissions.json")
      prev = Application.get_env(:optimal_system_agent, :permissions_file)
      Application.put_env(:optimal_system_agent, :permissions_file, path)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :permissions_file, prev),
          else: Application.delete_env(:optimal_system_agent, :permissions_file)
      end)

      {:ok, dir: dir, path: path}
    end

    test "saving a rule keeps every previously stored allow and deny" do
      assert :ok = Permissions.save_rule("file_write", :allow_always)
      assert :ok = Permissions.save_rule("shell_execute(rm:*)", :deny_always)
      assert :ok = Permissions.save_rule("file_edit", :allow_always)

      rules = Permissions.list_rules()
      assert rules["file_write"] == "allow"
      assert rules["shell_execute(rm:*)"] == "deny"
      assert rules["file_edit"] == "allow"
    end

    test "saving a rule over a corrupt permissions file refuses and preserves it", ctx do
      assert :ok = Permissions.save_rule("file_write", :allow_always)
      original = ~s|{"file_write": "allow", "shell_execute(rm:*)": "deny",}|
      File.write!(ctx.path, original)

      assert {:error, msg} = Permissions.save_rule("file_edit", :allow_always)
      assert msg =~ "Refusing"
      assert File.read!(ctx.path) == original
    end
  end

  # ── 5. Auto-generated skills overwriting hand-written ones ───────────

  describe "skill generator" do
    setup do
      root = tmp_dir("gen_skills")
      prev = Application.get_env(:optimal_system_agent, :skills_dir)
      Application.put_env(:optimal_system_agent, :skills_dir, root)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :skills_dir, prev),
          else: Application.delete_env(:optimal_system_agent, :skills_dir)
      end)

      {:ok, root: root}
    end

    # Must clear `SkillGenerator.skill_worthy?/1` (the Skills.Capture bar:
    # a real trigger and a substantive multi-step body), or generation is
    # refused as :low_signal before it ever reaches the file.
    @pattern %{
      id: "p1",
      description: "deploy the payments service to staging",
      trigger: "when deploying the payments service to a staging environment",
      response:
        "1. Run the migration task. 2. Build the release artifact. " <>
          "3. Push the image to the registry. 4. Roll the staging deployment.",
      category: "context",
      tags: "ops",
      occurrences: 99,
      confidence: 1.0
    }

    test "refuses to overwrite a hand-written SKILL.md", ctx do
      slug = generated_slug(ctx.root, @pattern)
      dir = Path.join(ctx.root, slug)
      File.mkdir_p!(dir)
      path = Path.join(dir, "SKILL.md")
      hand_written = "---\nname: #{slug}\ndescription: mine\n---\n\nDo not touch this.\n"
      File.write!(path, hand_written)

      assert {:error, :hand_written_skill} = SkillGenerator.generate_from_pattern(@pattern)
      assert File.read!(path) == hand_written
    end

    test "still regenerates a skill it produced itself", ctx do
      assert {:ok, path} = SkillGenerator.generate_from_pattern(@pattern)
      assert File.read!(path) =~ "source: auto:p1"
      assert String.starts_with?(path, ctx.root)

      assert {:ok, ^path} =
               SkillGenerator.generate_from_pattern(%{
                 @pattern
                 | response:
                     "1. Second revision of the procedure. 2. Build. " <>
                       "3. Push. 4. Roll the staging deployment."
               })

      assert File.read!(path) =~ "Second revision of the procedure"
    end

    # The slug is derived from the description; recover it by generating once
    # into a throwaway directory.
    defp generated_slug(root, pattern) do
      {:ok, path} = SkillGenerator.generate_from_pattern(pattern)
      slug = path |> Path.dirname() |> Path.basename()
      File.rm_rf!(Path.join(root, slug))
      slug
    end
  end

  # ── 8. Shared team ETS tables have a boot owner ──────────────────────

  describe "team table ownership" do
    alias OptimalSystemAgent.Teams.TableRegistry

    test "the shared tables exist without any team having been created" do
      # Created in Application.start/2 Phase 2. Without a boot owner these are
      # :undefined until the first team touches them.
      assert :ets.whereis(TableRegistry.meta_table()) != :undefined
      assert :ets.whereis(TableRegistry.agents_table()) != :undefined
    end

    test "a short-lived process creating a team does not own the shared tables" do
      parent = self()

      pid =
        spawn(fn ->
          TableRegistry.ensure_tables("ephemeral-team")
          send(parent, :ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :ready, 1_000
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # The tables — and therefore every OTHER live team's metadata and roster —
      # must survive that process exiting.
      assert :ets.whereis(TableRegistry.meta_table()) != :undefined
      assert :ets.whereis(TableRegistry.agents_table()) != :undefined
    end

    test "another team's rows survive one team being dissolved" do
      TableRegistry.ensure_tables("team-a")
      TableRegistry.ensure_tables("team-b")
      :ets.insert(TableRegistry.meta_table(), {TableRegistry.meta_key("team-b"), %{n: 1}})

      TableRegistry.destroy_tables("team-a")

      assert :ets.lookup(TableRegistry.meta_table(), TableRegistry.meta_key("team-b")) == [
               {TableRegistry.meta_key("team-b"), %{n: 1}}
             ]
    end
  end

  # ── 7. Heartbeat writes a stale pre-execution snapshot back ──────────

  describe "heartbeat write-back" do
    alias OptimalSystemAgent.Agent.Scheduler.Heartbeat

    setup do
      dir = tmp_dir("heartbeat")
      prev = Application.get_env(:optimal_system_agent, :config_dir)
      Application.put_env(:optimal_system_agent, :config_dir, dir)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :config_dir, prev),
          else: Application.delete_env(:optimal_system_agent, :config_dir)
      end)

      {:ok, dir: dir, path: Heartbeat.path()}
    end

    test "a task added while tasks were executing is not reverted", ctx do
      File.mkdir_p!(Path.dirname(ctx.path))
      File.write!(ctx.path, "# Heartbeat Tasks\n\n- [ ] first task\n")

      state = %{last_run: nil, failures: %{}}

      # The agent itself edits HEARTBEAT.md, and so does the user. Simulate
      # that landing DURING execution, which is where the old code read its
      # snapshot from before the run and wrote it back after.
      executor = fn task, _session ->
        File.write!(ctx.path, File.read!(ctx.path) <> "- [ ] added during the run\n")
        {:ok, "did #{task}"}
      end

      Heartbeat.run(state, executor)

      final = File.read!(ctx.path)

      assert final =~ "added during the run",
             "the heartbeat wrote a pre-execution snapshot back and lost a concurrent edit"

      # And the completed task must still have been marked.
      refute final =~ "- [ ] first task"
    end
  end
end
