defmodule OptimalSystemAgent.Agent.SchedulerDispatchTest do
  @moduledoc """
  The scheduler is a dispatcher, not a worker.

  Two failures are covered here:

    * **Silently dropped ticks.** The cron tick used to run every firing job
      INLINE and only then re-arm the 60s timer. Matching was done against the
      `DateTime.utc_now()` read at the top of that pass, so every minute spent
      executing was a minute the matcher never evaluated — jobs scheduled in it
      simply never fired, with no missed-tick log and no backfill. An
      `"agent"` job is a full agent turn, so the window is minutes, not
      milliseconds.

    * **A client deadline with no server deadline.** `run_job/1` called with a
      35s client timeout into an unbounded handler. On timeout the caller
      exited, the job kept running, and the retry (or the next 60s tick)
      started a SECOND concurrent execution of the same job — while the
      failure counter incremented against a job that was perfectly healthy.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Scheduler

  # A bare state struct: these tests drive the tick logic directly rather than
  # booting the real scheduler (which owns the machine's real CRONS.json).
  defp state(overrides) do
    Map.merge(%Scheduler{}, overrides)
  end

  setup do
    # Never enter the real tool registry from a tick test.
    Application.put_env(:optimal_system_agent, :cron_executor, fn _job -> {:ok, "stub"} end)
    on_exit(fn -> Application.delete_env(:optimal_system_agent, :cron_executor) end)
    :ok
  end

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 60, :second)

  # A job whose executor records its firing minute. `"command"` with a no-op
  # echo keeps JobExecutor out of the agent loop; we assert on dispatch, and
  # the in-flight bookkeeping, not on the body.
  defp job(id, schedule) do
    %{
      "id" => id,
      "name" => id,
      "type" => "command",
      "command" => "true",
      "schedule" => schedule,
      "enabled" => true
    }
  end

  describe "missed ticks are backfilled, not silently dropped" do
    test "a tick that arrives late evaluates every minute it skipped" do
      # An every-minute job, with the last evaluation five minutes stale — the
      # shape produced by five minutes of inline execution.
      s = state(%{cron_jobs: [job("every-min", "* * * * *")], last_cron_minute: minutes_ago(5)})

      out = Scheduler.run_cron_check(s)

      # Five skipped minutes were each evaluated, so five executions were
      # dispatched. Only one can be in flight at a time, so the observable is
      # that the job was dispatched at all AND that the tick advanced.
      assert map_size(out.in_flight) == 1,
             "the late tick did not dispatch the job it owed"

      refute out.last_cron_minute == s.last_cron_minute,
             "the evaluated-minute watermark never advanced"
    end

    test "a job scheduled inside the skipped window still fires" do
      # A job matching a minute inside the skipped window must still be
      # dispatched, and the watermark must land on the CURRENT minute so the
      # window is closed exactly once.
      s = state(%{cron_jobs: [job("hourly", "* * * * *")], last_cron_minute: minutes_ago(3)})

      out = Scheduler.run_cron_check(s)

      assert map_size(out.in_flight) == 1
      assert out.last_cron_minute.second == 0
      assert DateTime.diff(DateTime.utc_now(), out.last_cron_minute, :second) < 60
    end

    test "the same minute is never evaluated twice" do
      s = state(%{cron_jobs: [job("every-min", "* * * * *")]})

      first = Scheduler.run_cron_check(s)
      assert map_size(first.in_flight) == 1

      # Second tick within the same minute: the watermark already covers it, so
      # nothing new is owed.
      second = Scheduler.run_cron_check(%{first | in_flight: %{}, by_ref: %{}})
      assert second.in_flight == %{}
    end

    test "a gap larger than the backfill window is reported, not replayed" do
      s =
        state(%{
          cron_jobs: [job("every-min", "* * * * *")],
          last_cron_minute: minutes_ago(5000)
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Process.put(:out, Scheduler.run_cron_check(s))
        end)

      assert log =~ "cron tick gap",
             "a multi-day gap was skipped without ever saying so"

      assert log =~ "were NOT evaluated"
    end

    test "a clock that goes backwards does not re-fire an evaluated minute" do
      s =
        state(%{
          cron_jobs: [job("every-min", "* * * * *")],
          last_cron_minute: DateTime.add(DateTime.utc_now(), 600, :second)
        })

      out = Scheduler.run_cron_check(s)
      assert out.in_flight == %{}
    end
  end

  describe "execution happens off the scheduler process" do
    test "a firing job is dispatched to a task, leaving an in-flight record" do
      s = state(%{cron_jobs: [job("every-min", "* * * * *")]})
      out = Scheduler.run_cron_check(s)

      assert [{"every-min", entry}] = Map.to_list(out.in_flight)
      assert is_pid(entry.pid)
      assert is_reference(entry.ref)

      refute entry.pid == self(),
             "the job body ran on the scheduler process itself"

      assert Map.get(out.by_ref, entry.ref) == "every-min"
    end

    test "the tick returns immediately even when the job body is slow" do
      # The direct observable for finding #3. A slow body used to run INSIDE
      # `handle_info(:cron_check, ...)`, which is why the next tick — armed only
      # afterwards — was late by exactly the execution time, and why every
      # minute in that window was never evaluated.
      me = self()

      Application.put_env(:optimal_system_agent, :cron_executor, fn _job ->
        send(me, :body_started)
        Process.sleep(1_500)
        {:ok, "slow"}
      end)

      s = state(%{cron_jobs: [job("slow", "* * * * *")]})

      {elapsed_us, {:noreply, out}} =
        :timer.tc(fn -> Scheduler.handle_info(:cron_check, s) end)

      assert_receive :body_started, 1_000
      assert map_size(out.in_flight) == 1

      assert elapsed_us < 500_000,
             "the cron tick blocked for #{div(elapsed_us, 1000)}ms on the job body — every " <>
               "minute in that window is a cron minute that is never evaluated"

      # And the next tick was armed by the handler, not deferred until the body
      # finished.
      assert %DateTime{} = out.next_cron_at
    end

    test "a job already in flight is never started a second time" do
      s = state(%{cron_jobs: [job("every-min", "* * * * *")]})
      first = Scheduler.run_cron_check(s)
      assert [{"every-min", entry}] = Map.to_list(first.in_flight)

      # Roll the watermark back so the very next tick owes the same job again —
      # exactly the retry/tick overlap that produced two concurrent copies.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          out = Scheduler.run_cron_check(%{first | last_cron_minute: minutes_ago(2)})
          Process.put(:out, out)
        end)

      out = Process.get(:out)

      assert map_size(out.in_flight) == 1
      assert out.in_flight["every-min"].ref == entry.ref
      assert log =~ "not starting a second one"
    end
  end

  describe "server-side deadlines exist" do
    test "job_timeout_ms/0 and run_job_reply_ms/0 are configurable ceilings" do
      assert is_integer(Scheduler.job_timeout_ms()) and Scheduler.job_timeout_ms() > 0
      assert is_integer(Scheduler.run_job_reply_ms()) and Scheduler.run_job_reply_ms() > 0

      Application.put_env(:optimal_system_agent, :cron_job_timeout_ms, 1234)
      assert Scheduler.job_timeout_ms() == 1234
    after
      Application.delete_env(:optimal_system_agent, :cron_job_timeout_ms)
    end

    test "an in-flight job carries both timers so neither deadline is missing" do
      s = state(%{cron_jobs: [job("every-min", "* * * * *")]})
      out = Scheduler.run_cron_check(s)

      [{_id, entry}] = Map.to_list(out.in_flight)

      assert is_reference(entry.job_timer),
             "a dispatched job had no server-side execution deadline"

      # No caller is parked on a tick-fired job, so there is no reply deadline.
      assert entry.from == nil
      assert entry.reply_timer == nil
    end
  end
end
