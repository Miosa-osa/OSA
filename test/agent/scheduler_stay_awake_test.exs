defmodule OptimalSystemAgent.Agent.SchedulerStayAwakeTest do
  @moduledoc """
  A proactive agent needs the machine awake BETWEEN turns, not just during them.

  `StayAwake` holds an inhibitor for the length of a turn, which covers a task
  someone is waiting on. A cron due at 3am spends almost all of its life between
  turns: if the laptop idles out in that gap the job simply never fires. The
  scheduler's own backfill ceiling is the evidence — it exists because ticks DO
  get missed, and it replays at most an hour, so a night of sleep drops the rest.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Scheduler

  defp state(fields), do: struct(Scheduler, fields)

  # Point HEARTBEAT.md at a temp dir for the WHOLE module. Without this the
  # "nothing to do" cases read the operator's real ~/.osa/HEARTBEAT.md and pass
  # or fail on whatever happens to be in it - and any test that wrote to it
  # would be editing a real config file.
  setup do
    dir = Path.join(System.tmp_dir!(), "osa-heartbeat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.fetch_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      case previous do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :config_dir, v)
        :error -> Application.delete_env(:optimal_system_agent, :config_dir)
      end
    end)

    {:ok, config_dir: dir}
  end

  describe "work that must fire on its own" do
    test "an enabled cron job counts" do
      assert Scheduler.proactive_work?(state(cron_jobs: [%{"id" => "a", "enabled" => true}]))
    end

    test "an enabled trigger counts" do
      assert Scheduler.proactive_work?(state(triggers_raw: [%{"id" => "t", "enabled" => true}]))
    end

    test "a job with no explicit enabled key counts" do
      # A hand-edited CRONS.json may omit the key entirely; `add_job/1` only
      # supplies the default on the way through. Absent must not read as off.
      assert Scheduler.proactive_work?(state(cron_jobs: [%{"id" => "a"}]))
    end
  end

  describe "nothing to do means nothing to keep awake" do
    test "an empty scheduler does not hold the machine awake" do
      # OSA must not keep a laptop awake for a scheduler with no work.
      refute Scheduler.proactive_work?(state(cron_jobs: [], triggers_raw: []))
    end

    test "disabled jobs and triggers do not count" do
      refute Scheduler.proactive_work?(
               state(
                 cron_jobs: [%{"id" => "a", "enabled" => false}],
                 triggers_raw: [%{"id" => "t", "enabled" => false}]
               )
             )
    end

    test "one enabled job among disabled ones is enough" do
      assert Scheduler.proactive_work?(
               state(
                 cron_jobs: [
                   %{"id" => "a", "enabled" => false},
                   %{"id" => "b", "enabled" => true}
                 ]
               )
             )
    end
  end

  describe "HEARTBEAT.md" do
    setup do
      {:ok, path: Scheduler.heartbeat_path()}
    end

    test "an unchecked task counts as proactive work", %{path: path} do
      File.write!(path, "## Periodic Tasks\n\n- [ ] scan the inbox\n")
      assert Scheduler.proactive_work?(state(cron_jobs: [], triggers_raw: []))
    end

    test "a file with only completed tasks does not", %{path: path} do
      File.write!(path, "## Periodic Tasks\n\n- [x] scan the inbox (completed)\n")
      refute Scheduler.proactive_work?(state(cron_jobs: [], triggers_raw: []))
    end

    test "a missing file does not", %{path: path} do
      File.rm(path)
      refute Scheduler.proactive_work?(state(cron_jobs: [], triggers_raw: []))
    end
  end
end
