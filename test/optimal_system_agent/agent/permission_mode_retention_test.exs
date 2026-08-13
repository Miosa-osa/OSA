defmodule OptimalSystemAgent.Agent.PermissionModeRetentionTest do
  @moduledoc """
  Regression: the sticky permission-mode store is BOUNDED.

  Rows are keyed by session id, nothing calls `clear/1` at session end, and the
  whole table is rewritten to `~/.osa/permission_mode.json` on every single mode
  change. Without a bound, a daemon that has served many short-lived sessions
  (benchmarks, subagents) pays a growing serialize-and-write cost on every
  overdrive toggle, forever.

  Two bounds, both applied on write AND on load: age (30 days) and count (500,
  most-recently-updated wins).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.PermissionMode

  @table :osa_session_permission_mode
  @max_entries 500

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-pm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "permission_mode.json")

    prior = Application.get_env(:optimal_system_agent, :permission_mode_file)
    Application.put_env(:optimal_system_agent, :permission_mode_file, path)

    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)

    on_exit(fn ->
      if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)

      if prior,
        do: Application.put_env(:optimal_system_agent, :permission_mode_file, prior),
        else: Application.delete_env(:optimal_system_agent, :permission_mode_file)

      File.rm_rf(dir)
    end)

    {:ok, path: path}
  end

  describe "basic behaviour is unchanged" do
    test "a mode round-trips" do
      PermissionMode.put("s1", :overdrive)
      assert PermissionMode.get("s1") == :overdrive
      assert PermissionMode.overdrive?("s1")
    end

    test ":bypass is still canonicalised to :overdrive" do
      PermissionMode.put("s2", :bypass)
      assert PermissionMode.get("s2") == :overdrive
    end

    test "clear/1 forgets a session" do
      PermissionMode.put("s3", :plan)
      PermissionMode.clear("s3")
      assert PermissionMode.get("s3") == nil
    end
  end

  describe "count bound" do
    test "the store never exceeds @max_entries" do
      for i <- 1..(@max_entries + 25), do: PermissionMode.put("bulk-#{i}", :ask)

      assert PermissionMode.size() <= @max_entries,
             "permission_mode.json has no eviction again — it grows without limit"
    end

    test "eviction keeps the most recently updated entries" do
      for i <- 1..(@max_entries + 10), do: PermissionMode.put("old-#{i}", :ask)

      # Freshly written, so it must survive the trim that its own write triggers.
      PermissionMode.put("newest", :overdrive)
      assert PermissionMode.get("newest") == :overdrive
    end
  end

  describe "age bound" do
    test "an entry older than the retention window is evicted on the next write" do
      ancient = System.system_time(:millisecond) - 400 * 24 * 60 * 60 * 1000

      # Seed the table directly with an old timestamp — the store has no clock
      # injection point, and freezing time for a 30-day window is not worth a
      # dependency.
      PermissionMode.put("fresh", :ask)
      :ets.insert(@table, {"ancient", :overdrive, ancient})
      assert PermissionMode.get("ancient") == :overdrive

      # Any write runs eviction.
      PermissionMode.put("fresh", :ask)

      assert PermissionMode.get("ancient") == nil,
             "a 400-day-old sticky mode survived; the age bound is not being applied"

      assert PermissionMode.get("fresh") == :ask
    end
  end

  describe "disk persistence" do
    test "the file carries timestamps so the age bound survives a restart", %{path: path} do
      PermissionMode.put("s", :overdrive)

      assert {:ok, body} = File.read(path)
      assert {:ok, %{"s" => entry}} = Jason.decode(body)
      assert entry["mode"] == "overdrive"
      assert is_integer(entry["updated_at"])
    end

    test "a legacy file (bare mode strings) still loads", %{path: path} do
      File.write!(path, Jason.encode!(%{"legacy" => "overdrive", "junk" => "not_a_mode"}))

      # Force a rehydrate: drop the table so ensure_table/0 reloads from disk.
      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

      assert PermissionMode.get("legacy") == :overdrive,
             "upgrading must not silently switch a user's overdrive off"

      assert PermissionMode.get("junk") == nil
    end

    test "a file that grew unbounded under an older build is trimmed on load", %{path: path} do
      oversized =
        1..(@max_entries + 200)
        |> Map.new(fn i -> {"legacy-#{i}", "ask"} end)

      File.write!(path, Jason.encode!(oversized))

      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

      # First touch rehydrates + evicts + rewrites.
      PermissionMode.get("legacy-1")

      assert PermissionMode.size() <= @max_entries

      assert {:ok, body} = File.read(path)
      assert {:ok, map} = Jason.decode(body)
      assert map_size(map) <= @max_entries
    end
  end
end
