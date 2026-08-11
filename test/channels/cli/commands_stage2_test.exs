defmodule OptimalSystemAgent.Channels.CLI.CommandsStage2Test do
  @moduledoc """
  Stage 2/3 backend command handlers: /mcp, /init, /copy, /files, /rename,
  /tag, /sandbox, and /permissions add. Each is exercised through the single
  `Commands.dispatch/2` entrypoint so the unified-registry path is covered too.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.{Loop, SessionPersistence}
  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Permissions

  defp uid, do: System.unique_integer([:positive, :monotonic])

  # ── Unified registry ─────────────────────────────────────────────────

  describe "command registry (single source of truth)" do
    test "new commands are registered with descriptions" do
      names = Commands.list_with_descriptions() |> Enum.map(&elem(&1, 0))

      for cmd <- ~w(mcp init copy files rename tag sandbox) do
        assert cmd in names, "expected /#{cmd} to be registered"
      end
    end

    test "list/0 stays sorted and includes the new commands" do
      list = Commands.list()
      assert list == Enum.sort(list)
      assert "sandbox" in list
      assert "rename" in list
    end

    test "unknown slash routes through dispatch and suggests, returning session_id" do
      out = capture_io(fn -> assert "sess-x" = Commands.dispatch("saandbox", "sess-x") end)
      assert out =~ "unknown command"
    end
  end

  # ── /init ────────────────────────────────────────────────────────────

  describe "/init" do
    test "init_prompt names OSA's AGENTS.md guide, never CLAUDE.md" do
      prompt = Commands.init_prompt()
      assert prompt =~ "AGENTS.md"
      refute prompt =~ "CLAUDE.md"
    end

    test "dispatch prints the seed prompt when no live queue exists" do
      sid = "init-#{uid()}"
      out = capture_io(fn -> assert ^sid = Commands.dispatch("init", sid) end)
      assert out =~ "AGENTS.md"
    end
  end

  # ── /mcp ─────────────────────────────────────────────────────────────

  describe "/mcp" do
    test "lists servers without crashing and returns session_id" do
      sid = "mcp-#{uid()}"
      out = capture_io(fn -> assert ^sid = Commands.dispatch("mcp", sid) end)
      assert out =~ "MCP Servers"
    end
  end

  # ── /copy ────────────────────────────────────────────────────────────

  describe "/copy" do
    test "reports nothing to copy when session has no messages" do
      sid = "copy-none-#{uid()}"
      out = capture_io(fn -> assert ^sid = Commands.dispatch("copy", sid) end)
      assert out =~ "No assistant reply"
    end

    test "emits the last assistant reply from a live loop" do
      sid = "copy-live-#{uid()}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: sid, channel: :test}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | messages: [
              %{role: "user", content: "hi"},
              %{role: "assistant", content: "SENTINEL_REPLY_TEXT"}
            ]
        }
      end)

      out = capture_io(fn -> assert ^sid = Commands.dispatch("copy", sid) end)
      assert out =~ "SENTINEL_REPLY_TEXT"
    end
  end

  # ── /files ───────────────────────────────────────────────────────────

  describe "/files" do
    test "renders the header and returns session_id" do
      sid = "files-#{uid()}"
      out = capture_io(fn -> assert ^sid = Commands.dispatch("files", sid) end)
      assert out =~ "Files in Context"
    end

    test "lists @file references found in session user messages" do
      sid = "files-ref-#{uid()}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: sid, channel: :test}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      :sys.replace_state(pid, fn state ->
        %{state | messages: [%{role: "user", content: "look at @file:lib/foo.ex please"}]}
      end)

      out = capture_io(fn -> assert ^sid = Commands.dispatch("files", sid) end)
      assert out =~ "lib/foo.ex"
    end
  end

  # ── /rename + /tag (persisted metadata) ──────────────────────────────

  describe "/rename and /tag" do
    test "rename persists a title on the session record" do
      sid = "rename-#{uid()}"
      on_exit(fn -> SessionPersistence.delete(sid) end)

      out = capture_io(fn -> assert ^sid = Commands.dispatch("rename My Cool Session", sid) end)
      assert out =~ "renamed"

      assert %{title: "My Cool Session"} = SessionPersistence.get_metadata(sid)
    end

    test "tag appends unique tags on the session record" do
      sid = "tag-#{uid()}"
      on_exit(fn -> SessionPersistence.delete(sid) end)

      capture_io(fn -> Commands.dispatch("tag backend", sid) end)
      capture_io(fn -> Commands.dispatch("tag urgent", sid) end)
      # duplicate should not double-add
      capture_io(fn -> Commands.dispatch("tag backend", sid) end)

      %{tags: tags} = SessionPersistence.get_metadata(sid)
      assert Enum.sort(tags) == ["backend", "urgent"]
    end

    test "message-only save preserves title/tags set via metadata" do
      sid = "preserve-#{uid()}"
      on_exit(fn -> SessionPersistence.delete(sid) end)

      :ok = SessionPersistence.update_metadata(sid, %{title: "Keep Me", tags: ["x"]})
      # A later message-only save must not clobber the metadata.
      :ok = SessionPersistence.save(sid, [%{role: "user", content: "hello"}])

      meta = SessionPersistence.get_metadata(sid)
      assert meta.title == "Keep Me"
      assert meta.tags == ["x"]

      # And the messages were actually saved.
      assert {:ok, [%{content: "hello"}]} = SessionPersistence.load(sid)
    end

    test "list/1 surfaces title and tags" do
      sid = "list-meta-#{uid()}"
      on_exit(fn -> SessionPersistence.delete(sid) end)

      :ok = SessionPersistence.update_metadata(sid, %{title: "Listed", tags: ["t1"]})

      entry = SessionPersistence.list() |> Enum.find(&(&1.session_id == sid))
      assert entry.title == "Listed"
      assert entry.tags == ["t1"]
    end
  end

  # ── /sandbox ─────────────────────────────────────────────────────────

  describe "/sandbox" do
    setup do
      original = Application.get_env(:optimal_system_agent, :sandbox_backend)
      tmp = Path.join(System.tmp_dir!(), "osa-test-sandbox-#{uid()}.json")

      Application.put_env(:optimal_system_agent, :sandbox_config_file, tmp)

      on_exit(fn ->
        if original,
          do: Application.put_env(:optimal_system_agent, :sandbox_backend, original),
          else: Application.delete_env(:optimal_system_agent, :sandbox_backend)

        Application.delete_env(:optimal_system_agent, :sandbox_config_file)
        File.rm(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "lists the registered backends" do
      sid = "sbx-#{uid()}"
      out = capture_io(fn -> assert ^sid = Commands.dispatch("sandbox", sid) end)
      assert out =~ "Sandbox Backends"

      for b <- ~w(host docker e2b miosa vercel) do
        assert out =~ b
      end
    end

    test "switching sets the runtime backend and persists it", %{tmp: tmp} do
      sid = "sbx-switch-#{uid()}"
      out = capture_io(fn -> assert ^sid = Commands.dispatch("sandbox docker", sid) end)
      assert out =~ "set to"

      assert Application.get_env(:optimal_system_agent, :sandbox_backend) == :docker

      assert {:ok, %{"backend" => "docker"}} =
               File.read(tmp) |> then(&(&1 |> elem(1) |> Jason.decode()))
    end

    test "rejects an unknown backend" do
      sid = "sbx-bad-#{uid()}"
      out = capture_io(fn -> assert ^sid = Commands.dispatch("sandbox nonsense", sid) end)
      assert out =~ "unknown backend"
    end
  end

  # ── /permissions add ─────────────────────────────────────────────────

  describe "/permissions add/remove" do
    test "add persists an allow rule; remove clears it" do
      tool = "shell_execute_test_#{uid()}"

      capture_io(fn -> Commands.dispatch("permissions add #{tool} allow", "p-#{uid()}") end)
      assert Permissions.list_rules()[tool] == "allow"

      capture_io(fn -> Commands.dispatch("permissions remove #{tool}", "p-#{uid()}") end)
      refute Map.has_key?(Permissions.list_rules(), tool)
    end

    test "add with a bad action shows usage and does not persist" do
      tool = "bad_action_tool_#{uid()}"
      out = capture_io(fn -> Commands.dispatch("permissions add #{tool} maybe", "p-#{uid()}") end)
      assert out =~ "Usage"
      refute Map.has_key?(Permissions.list_rules(), tool)
    end
  end
end
