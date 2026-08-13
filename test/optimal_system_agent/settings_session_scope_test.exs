defmodule OptimalSystemAgent.SettingsSessionScopeTest do
  @moduledoc """
  Regression: the settings **session layer** is per-session, not per-daemon.

  `set_session/2` wrote a single `{{:session, key}, value}` row into one
  daemon-wide ETS table, so every concurrent session in a backend shared it.
  That — not the cwd — is what made per-session tool policy impossible: setting
  "no network tools" for one benchmark run also set it for the operator's
  interactive session in another directory.

  (The FILE layers were already session-scoped in practice: they resolve through
  `Workspace.Cwd.get/0`, which the loop overrides per process at the start of
  every turn. Two sessions sharing ONE directory still share those files, which
  is correct — they are properties of the directory. See the moduledoc of
  `OptimalSystemAgent.Settings` for what a complete per-session overlay would
  still need.)
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings

  setup do
    ensure_table()
    :ets.delete_all_objects(:osa_settings)
    Process.delete(:osa_session_id)

    on_exit(fn ->
      if :ets.whereis(:osa_settings) != :undefined,
        do: :ets.delete_all_objects(:osa_settings)
    end)

    :ok
  end

  defp ensure_table do
    if :ets.whereis(:osa_settings) == :undefined do
      :ets.new(:osa_settings, [:named_table, :public, :set])
    end

    :ok
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])

  describe "current_session/0" do
    test "is :global with no session published" do
      assert Settings.current_session() == :global
    end

    test "is the process's session id once published" do
      Process.put(:osa_session_id, "sess-a")
      assert Settings.current_session() == "sess-a"
    end
  end

  describe "per-session values" do
    test "a value set for one session is invisible to another" do
      a = "sess-a-#{unique()}"
      b = "sess-b-#{unique()}"

      Settings.set_session_for(a, "network_tools_enabled", false)

      Process.put(:osa_session_id, a)
      assert Settings.get("network_tools_enabled") == false

      Process.put(:osa_session_id, b)

      assert Settings.get("network_tools_enabled", :unset) == :unset,
             "session B can see session A's setting — the layer is still daemon-wide"
    end

    test "a session value shadows the global value for that session only" do
      a = "sess-a-#{unique()}"

      Settings.set_session_for(nil, "effort_level", "high")
      Settings.set_session_for(a, "effort_level", "low")

      Process.put(:osa_session_id, a)
      assert Settings.get("effort_level") == "low"

      Process.delete(:osa_session_id)
      assert Settings.get("effort_level") == "high"
    end

    test "set_session/2 scopes to the calling process's session when there is one" do
      a = "sess-a-#{unique()}"
      Process.put(:osa_session_id, a)
      Settings.set_session("personality", "terse")

      Process.delete(:osa_session_id)

      assert Settings.get("personality", :unset) == :unset,
             "a session-scoped write leaked into the global scope"

      Process.put(:osa_session_id, a)
      assert Settings.get("personality") == "terse"
    end

    test "set_session/2 stays global when no session is in context" do
      # Existing callers (CLI /effort, /personality typed outside a turn, tests)
      # must keep working exactly as before.
      Settings.set_session("effort_level", "medium")
      assert Settings.get("effort_level") == "medium"
      assert Settings.layer(:session)["effort_level"] == "medium"
    end

    test "concurrent processes acting for different sessions do not interfere" do
      a = "sess-a-#{unique()}"
      b = "sess-b-#{unique()}"
      Settings.set_session_for(a, "model", "a-model")
      Settings.set_session_for(b, "model", "b-model")

      task = fn sid ->
        Task.async(fn ->
          Process.put(:osa_session_id, sid)
          Settings.get("model")
        end)
      end

      assert Task.await(task.(a)) == "a-model"
      assert Task.await(task.(b)) == "b-model"
    end
  end

  describe "clear_session/1" do
    test "drops only the named session's rows" do
      a = "sess-a-#{unique()}"
      b = "sess-b-#{unique()}"
      Settings.set_session_for(a, "k", 1)
      Settings.set_session_for(b, "k", 2)
      Settings.set_session_for(nil, "k", 0)

      Settings.clear_session(a)

      Process.put(:osa_session_id, a)
      assert Settings.get("k") == 0, "session A should fall back to the global row"

      Process.put(:osa_session_id, b)
      assert Settings.get("k") == 2
    end
  end

  describe "the old row shape still works" do
    test "a raw {{:session, key}, value} row is still read as global" do
      :ets.insert(:osa_settings, {{:session, :effort_level}, "ultra"})
      assert Settings.get("effort_level") == "ultra"

      Process.put(:osa_session_id, "sess-#{unique()}")

      assert Settings.get("effort_level") == "ultra",
             "a session with no override of its own must still see the global row"
    end
  end
end
