defmodule OptimalSystemAgent.Agent.HeartbeatStateTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.HeartbeatState

  # Each test gets its own temp state file for isolation.
  # We must stop any globally-registered instance first since HeartbeatState
  # uses `name: __MODULE__` and may be started by the application supervisor.
  setup do
    # Stop any globally-registered instance and wait for name release
    wait_for_name_available = fn ->
      Enum.reduce_while(1..50, :ok, fn _, _ ->
        case GenServer.whereis(HeartbeatState) do
          nil -> {:halt, :ok}
          pid ->
            try do
              GenServer.stop(pid, :normal)
            catch
              :exit, _ -> :ok
            end
            Process.sleep(10)
            {:cont, :ok}
        end
      end)
    end

    wait_for_name_available.()

    tmp_dir = System.tmp_dir!()

    state_file =
      Path.join(tmp_dir, "heartbeat_state_test_#{:erlang.unique_integer([:positive])}.json")

    # Clean up any leftover file
    File.rm(state_file)

    pid = start_supervised!({HeartbeatState, state_file: state_file})

    on_exit(fn ->
      File.rm(state_file)
      File.rm(state_file <> ".tmp")
    end)

    %{state_file: state_file, pid: pid}
  end

  # ---------------------------------------------------------------------------
  # record_check/2
  # ---------------------------------------------------------------------------

  describe "record_check/2" do
    test "saves check info" do
      HeartbeatState.record_check(:cpu_check, :ok)
      # Cast is async, give it a moment
      Process.sleep(50)

      assert {:ok, info} = HeartbeatState.last_check(:cpu_check)
      assert info.result == :ok
      assert info.run_count == 1
      assert is_binary(info.last_run)
    end

    test "increments run_count on subsequent checks" do
      HeartbeatState.record_check(:disk_check, :ok)
      Process.sleep(20)
      HeartbeatState.record_check(:disk_check, :warning)
      Process.sleep(20)
      HeartbeatState.record_check(:disk_check, :ok)
      Process.sleep(20)

      assert {:ok, info} = HeartbeatState.last_check(:disk_check)
      assert info.run_count == 3
      assert info.result == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # last_check/1
  # ---------------------------------------------------------------------------

  describe "last_check/1" do
    test "returns recorded check" do
      HeartbeatState.record_check(:memory_check, %{usage_mb: 512})
      Process.sleep(50)

      assert {:ok, info} = HeartbeatState.last_check(:memory_check)
      assert info.result == %{usage_mb: 512}
      assert info.run_count == 1
    end

    test "returns not_found for unknown type" do
      assert :not_found = HeartbeatState.last_check(:nonexistent_check)
    end
  end

  # ---------------------------------------------------------------------------
  # in_quiet_hours?/0
  # ---------------------------------------------------------------------------

  describe "in_quiet_hours?/0" do
    test "returns false when no quiet hours configured" do
      refute HeartbeatState.in_quiet_hours?()
    end

    test "returns true during quiet hours" do
      now = DateTime.utc_now()
      # Set quiet hours that span the current time
      start_hour = now.hour
      start_min = 0
      end_hour = rem(now.hour + 2, 24)
      end_min = 0

      :ok = HeartbeatState.set_quiet_hours([{start_hour, start_min, end_hour, end_min}])

      assert HeartbeatState.in_quiet_hours?()
    end

    test "returns false outside quiet hours" do
      now = DateTime.utc_now()
      # Set quiet hours that DON'T include the current time
      # Use hours well away from current time
      far_start = rem(now.hour + 6, 24)
      far_end = rem(now.hour + 8, 24)

      :ok = HeartbeatState.set_quiet_hours([{far_start, 0, far_end, 0}])

      refute HeartbeatState.in_quiet_hours?()
    end
  end

  # ---------------------------------------------------------------------------
  # set_quiet_hours/1
  # ---------------------------------------------------------------------------

  describe "set_quiet_hours/1" do
    test "updates ranges" do
      ranges = [{23, 0, 8, 0}, {12, 0, 13, 0}]
      assert :ok = HeartbeatState.set_quiet_hours(ranges)

      # Verify by checking that the overnight range works
      result = HeartbeatState.check_quiet_hours(ranges, %{hour: 23, minute: 30})
      assert result == true

      result = HeartbeatState.check_quiet_hours(ranges, %{hour: 10, minute: 0})
      assert result == false

      result = HeartbeatState.check_quiet_hours(ranges, %{hour: 12, minute: 30})
      assert result == true
    end
  end

  # ---------------------------------------------------------------------------
  # Persistence — state survives restart
  # ---------------------------------------------------------------------------

  describe "persistence" do
    test "state persists and reloads from file", %{state_file: state_file} do
      # Record a check
      HeartbeatState.record_check(:persist_test, :passed)
      Process.sleep(50)

      # Verify it was saved
      assert {:ok, _info} = HeartbeatState.last_check(:persist_test)

      # Stop the current GenServer
      stop_supervised!(HeartbeatState)

      # Verify the file exists on disk
      assert File.exists?(state_file)

      # Start a new instance with the same state file
      start_supervised!({HeartbeatState, state_file: state_file})

      # After JSON round-trip, atom results become strings
      assert {:ok, info} = HeartbeatState.last_check(:persist_test)
      assert info.result == "passed"  # Atom :passed → string "passed" after JSON round-trip
      assert info.run_count == 1
    end

    test "handles missing state file gracefully" do
      # Stop and remove the file
      stop_supervised!(HeartbeatState)

      nonexistent =
        Path.join(System.tmp_dir!(), "does_not_exist_#{:erlang.unique_integer([:positive])}.json")

      start_supervised!({HeartbeatState, state_file: nonexistent})

      # Should start fine with empty state
      assert :not_found = HeartbeatState.last_check(:any)

      File.rm(nonexistent)
    end
  end

  # ---------------------------------------------------------------------------
  # parse_quiet_hours_string/1 — unit tests for parser
  # ---------------------------------------------------------------------------

  describe "parse_quiet_hours_string/1" do
    test "parses single range" do
      assert [{23, 0, 8, 0}] = HeartbeatState.parse_quiet_hours_string("23:00-08:00")
    end

    test "parses multiple comma-separated ranges" do
      result = HeartbeatState.parse_quiet_hours_string("23:00-08:00,12:00-13:00")
      assert [{23, 0, 8, 0}, {12, 0, 13, 0}] = result
    end

    test "handles whitespace" do
      result = HeartbeatState.parse_quiet_hours_string(" 23:00 - 08:00 , 12:00 - 13:00 ")
      assert [{23, 0, 8, 0}, {12, 0, 13, 0}] = result
    end

    test "returns empty list for invalid format" do
      assert [] = HeartbeatState.parse_quiet_hours_string("invalid")
    end
  end

  # ---------------------------------------------------------------------------
  # check_quiet_hours/2 — pure function tests
  # ---------------------------------------------------------------------------

  describe "check_quiet_hours/2" do
    test "overnight range: 23:00-08:00 includes 23:30" do
      assert HeartbeatState.check_quiet_hours([{23, 0, 8, 0}], %{hour: 23, minute: 30})
    end

    test "overnight range: 23:00-08:00 includes 02:00" do
      assert HeartbeatState.check_quiet_hours([{23, 0, 8, 0}], %{hour: 2, minute: 0})
    end

    test "overnight range: 23:00-08:00 excludes 10:00" do
      refute HeartbeatState.check_quiet_hours([{23, 0, 8, 0}], %{hour: 10, minute: 0})
    end

    test "same-day range: 12:00-13:00 includes 12:30" do
      assert HeartbeatState.check_quiet_hours([{12, 0, 13, 0}], %{hour: 12, minute: 30})
    end

    test "same-day range: 12:00-13:00 excludes 14:00" do
      refute HeartbeatState.check_quiet_hours([{12, 0, 13, 0}], %{hour: 14, minute: 0})
    end

    test "empty ranges always returns false" do
      refute HeartbeatState.check_quiet_hours([], %{hour: 12, minute: 0})
    end
  end
end
