defmodule OptimalSystemAgent.Tools.Builtins.ScratchpadToolTest do
  @moduledoc """
  Tests the `scratchpad` builtin tool end-to-end through its Handler, using an
  injected `__session_id__` (as the agent loop does) and a tmp config_dir seam.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Tools.Builtins.Scratchpad.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    prev_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_boot = Application.get_env(:optimal_system_agent, :bootstrap_dir)

    tmp =
      Path.join(System.tmp_dir!(), "osa_scratchpad_tool_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)
    Application.delete_env(:optimal_system_agent, :bootstrap_dir)
    ConfigFile.reload()

    on_exit(fn ->
      restore(:config_dir, prev_dir)
      restore(:bootstrap_dir, prev_boot)
      ConfigFile.reload()
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, v), do: Application.put_env(:optimal_system_agent, key, v)

  # Helper: run the tool via its handler with an injected session id.
  defp run(args, session_id) do
    Handler.execute(Map.put(args, "__session_id__", session_id), UseContext.empty())
  end

  describe "validation" do
    test "missing action is rejected" do
      assert {:error, _msg, -32_602} = Handler.validate(%{}, nil)
    end

    test "unknown action is rejected" do
      assert {:error, msg, -32_602} = Handler.validate(%{"action" => "explode"}, nil)
      assert msg =~ "Unknown action"
    end

    test "write without name is rejected" do
      assert {:error, msg, -32_602} = Handler.validate(%{"action" => "write", "content" => "x"}, nil)
      assert msg =~ "name"
    end

    test "write without content is rejected" do
      assert {:error, msg, -32_602} = Handler.validate(%{"action" => "write", "name" => "a.md"}, nil)
      assert msg =~ "content"
    end
  end

  describe "actions" do
    test "write then read round-trips through the tool" do
      assert {:ok, _} =
               run(%{"action" => "write", "name" => "n.md", "content" => "hi"}, "sess-1")

      assert {:ok, "hi"} = run(%{"action" => "read", "name" => "n.md"}, "sess-1")
    end

    test "append accumulates through the tool" do
      run(%{"action" => "write", "name" => "l.md", "content" => "a"}, "sess-1")
      run(%{"action" => "append", "name" => "l.md", "content" => "b"}, "sess-1")
      assert {:ok, "ab"} = run(%{"action" => "read", "name" => "l.md"}, "sess-1")
    end

    test "list shows written entries" do
      run(%{"action" => "write", "name" => "a.md", "content" => "x"}, "sess-1")
      assert {:ok, listing} = run(%{"action" => "list"}, "sess-1")
      assert listing =~ "a.md"
    end

    test "a fresh session lists as empty" do
      assert {:ok, msg} = run(%{"action" => "list"}, "fresh-session")
      assert msg =~ "empty"
    end

    test "delete removes an entry" do
      run(%{"action" => "write", "name" => "a.md", "content" => "x"}, "sess-1")
      assert {:ok, _} = run(%{"action" => "delete", "name" => "a.md"}, "sess-1")
      assert {:ok, msg} = run(%{"action" => "read", "name" => "a.md"}, "sess-1")
      assert msg =~ "not found"
    end
  end

  describe "path safety through the tool" do
    test "a '..' name is rejected, not written" do
      assert {:ok, msg} =
               run(%{"action" => "write", "name" => "../evil.md", "content" => "x"}, "sess-1")

      assert msg =~ "Rejected"
    end

    test "an absolute path name is rejected" do
      assert {:ok, msg} =
               run(%{"action" => "write", "name" => "/tmp/evil.md", "content" => "x"}, "sess-1")

      assert msg =~ "Rejected"
    end
  end

  describe "sharing / isolation through the tool" do
    test "two agents with the same session id share entries" do
      run(%{"action" => "write", "name" => "shared.md", "content" => "team data"}, "team-sess")
      # A different injected agent id but the SAME session id → same dir.
      assert {:ok, "team data"} = run(%{"action" => "read", "name" => "shared.md"}, "team-sess")
    end

    test "an explicit team_id scopes sharing across sessions" do
      run(
        %{"action" => "write", "name" => "t.md", "content" => "by team", "team_id" => "team-42"},
        "sess-a"
      )

      # A DIFFERENT session reading the SAME team_id sees it.
      assert {:ok, "by team"} =
               run(%{"action" => "read", "name" => "t.md", "team_id" => "team-42"}, "sess-b")
    end

    test "different sessions without a team_id are isolated" do
      run(%{"action" => "write", "name" => "x.md", "content" => "only-a"}, "sess-a")
      assert {:ok, msg} = run(%{"action" => "read", "name" => "x.md"}, "sess-b")
      assert msg =~ "not found"
    end
  end

  describe "scratchpad_activity emission" do
    setup do
      # The coordination id for a plain injected session (no RunStore parent) is
      # the session itself, so that IS the topic the TUI would stream.
      sid = "activity-sess-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
      {:ok, session_id: sid}
    end

    test "write emits a compact scratchpad_activity with no file contents", %{session_id: sid} do
      assert {:ok, msg} =
               run(%{"action" => "write", "name" => "findings.md", "content" => "hello team"}, sid)

      assert msg =~ "Wrote findings.md"

      # Reaches the TUI session topic via the TuiForwarder allowlist.
      assert_receive {:osa_event, event}, 2000
      assert event.event == :scratchpad_activity
      assert event.agent == sid
      assert event.entry == "findings.md"
      assert event.action == :write
      assert event.bytes == byte_size("hello team")
      # Payload stays small: who/what/size only, never the file body.
      refute Map.has_key?(event, :content)
    end

    test "append emits with the :append action", %{session_id: sid} do
      run(%{"action" => "write", "name" => "log.md", "content" => "a"}, sid)
      assert_receive {:osa_event, %{action: :write}}, 2000

      assert {:ok, _} = run(%{"action" => "append", "name" => "log.md", "content" => "bcd"}, sid)
      assert_receive {:osa_event, %{event: :scratchpad_activity, action: :append, bytes: 3}}, 2000
    end

    test "a write still succeeds when the emit is stubbed to fail", %{session_id: sid} do
      prev = Application.get_env(:optimal_system_agent, :scratchpad_emit_fun)

      Application.put_env(:optimal_system_agent, :scratchpad_emit_fun, fn _type, _payload ->
        raise "boom"
      end)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :scratchpad_emit_fun, prev),
          else: Application.delete_env(:optimal_system_agent, :scratchpad_emit_fun)
      end)

      # The write must complete cleanly despite the raising emitter.
      assert {:ok, msg} =
               run(%{"action" => "write", "name" => "robust.md", "content" => "still ok"}, sid)

      assert msg =~ "Wrote robust.md"
      # And the entry really landed on disk.
      assert {:ok, "still ok"} = run(%{"action" => "read", "name" => "robust.md"}, sid)
    end
  end

  describe "tool declarations" do
    test "schema is tight (no Type.Union / anyOf / oneOf / raw format)" do
      schema = Tool.parameters()
      encoded = Jason.encode!(schema)
      refute encoded =~ "anyOf"
      refute encoded =~ "oneOf"
      refute Map.has_key?(schema["properties"], "format")
    end

    test "read/list are read-only, write/delete are not" do
      assert Tool.read_only?(%{"action" => "read"}, nil)
      assert Tool.read_only?(%{"action" => "list"}, nil)
      refute Tool.read_only?(%{"action" => "write"}, nil)
      assert Tool.destructive?(%{"action" => "delete"}, nil)
    end
  end
end
