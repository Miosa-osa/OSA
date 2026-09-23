defmodule OptimalSystemAgent.Shell.BackgroundTaskExitStatusTest do
  @moduledoc """
  Background shell commands:

    1. A benign non-zero exit (`grep`/`diff`/`test` returning "no matches" /
       "differs" / "false") must complete as `:done`, not `:failed` — see
       `ExitClassifier`.
    2. A genuinely failing command must still report `:failed`.
    3. The completion notification carries the FINAL output and the exit
       status together, in ONE broadcast — never a separate "here's the last
       output" event followed by a second "it exited" event.
    4. Stopping a background task logs WHY it was stopped.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.Shell.BackgroundManager
  alias OptimalSystemAgent.Shell.TaskOutput

  defp sid(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  defp session_dir(s), do: s |> TaskOutput.path("probe") |> Path.dirname() |> Path.dirname()

  defp await_completion(session_id) do
    receive do
      {:osa_event, %{type: :background_command_completed} = ev} -> ev
    after
      15_000 -> flunk("no :background_command_completed for #{session_id}")
    end
  end

  setup do
    s = sid("bgexit")
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{s}")
    on_exit(fn -> File.rm_rf(session_dir(s)) end)
    {:ok, session: s}
  end

  describe "benign non-zero exits complete, they do not fail" do
    test "grep with no matches completes as :done", %{session: s} do
      dir = System.tmp_dir!()
      file = Path.join(dir, "haystack-#{System.unique_integer([:positive])}.txt")
      File.write!(file, "nothing interesting here\n")
      on_exit(fn -> File.rm(file) end)

      {:ok, id} = BackgroundManager.start("grep NEEDLE #{file}", dir, session_id: s)

      ev = await_completion(s)
      assert ev[:background_id] == id
      assert ev[:exit_code] == 1
      assert ev[:status] == :done, "grep exit 1 (no matches) must not be reported as :failed"
    end

    test "diff on differing files completes as :done", %{session: s} do
      dir = System.tmp_dir!()
      a = Path.join(dir, "a-#{System.unique_integer([:positive])}.txt")
      b = Path.join(dir, "b-#{System.unique_integer([:positive])}.txt")
      File.write!(a, "one\n")
      File.write!(b, "two\n")

      on_exit(fn ->
        File.rm(a)
        File.rm(b)
      end)

      {:ok, _id} = BackgroundManager.start("diff #{a} #{b}", dir, session_id: s)

      ev = await_completion(s)
      assert ev[:exit_code] == 1
      assert ev[:status] == :done
    end

    test "test -f on a missing file completes as :done", %{session: s} do
      {:ok, _id} =
        BackgroundManager.start("test -f /no/such/file/anywhere", System.tmp_dir!(),
          session_id: s
        )

      ev = await_completion(s)
      assert ev[:exit_code] == 1
      assert ev[:status] == :done
    end
  end

  describe "real failures still fail" do
    test "a plain nonzero exit is still :failed", %{session: s} do
      {:ok, _id} = BackgroundManager.start("exit 1", System.tmp_dir!(), session_id: s)

      ev = await_completion(s)
      assert ev[:exit_code] == 1
      assert ev[:status] == :failed
    end

    test "grep piped into a plain failure is classified by the LAST stage, not grep", %{
      session: s
    } do
      dir = System.tmp_dir!()
      file = Path.join(dir, "haystack2-#{System.unique_integer([:positive])}.txt")
      File.write!(file, "nothing interesting here\n")
      on_exit(fn -> File.rm(file) end)

      # `grep NEEDLE file | false` — the pipeline's reported exit code is the
      # LAST stage's (`false`, a plain generic failure, unrelated to "no
      # matches"), so this must stay :failed rather than being reclassified
      # just because `grep` appears earlier in the line.
      {:ok, _id} = BackgroundManager.start("grep NEEDLE #{file} | false", dir, session_id: s)

      ev = await_completion(s)
      assert ev[:status] == :failed
    end
  end

  describe "the completion notification is a single, merged broadcast" do
    test "final output and exit status arrive together, exactly once", %{session: s} do
      {:ok, _id} =
        BackgroundManager.start("printf 'line1\\nline2\\n'", System.tmp_dir!(), session_id: s)

      ev = await_completion(s)
      assert ev[:exit_code] == 0
      assert ev[:output_tail] =~ "line2"

      # No second completion notification should follow for the same task.
      refute_receive {:osa_event, %{type: :background_command_completed}}, 500
    end
  end

  describe "stopping a background task logs why" do
    # The test env pins the primary Logger at :warning (config/test.exs), so an
    # :info line never reaches the capture handler regardless of the `level:`
    # option passed to `capture_log/2` — that option only bounds what the
    # CAPTURE handler keeps, not whether the primary Logger dispatches the
    # message at all. Lower the primary level for these two assertions only,
    # same as `eviction_test.exs`'s "an optional drop is still logged" test.
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "an explicit kill logs the given reason", %{session: s} do
      {:ok, id} = BackgroundManager.start("sleep 30", System.tmp_dir!(), session_id: s)

      log =
        capture_log([level: :info], fn ->
          {:ok, _snap} = BackgroundManager.kill(id, "test: explicit stop")
          # Allow the async log call inside the GenServer to flush.
          Process.sleep(50)
        end)

      assert log =~ "test: explicit stop"
      assert log =~ id
    end

    test "kill_for_session logs 'session ended'", %{session: s} do
      {:ok, _id} = BackgroundManager.start("sleep 30", System.tmp_dir!(), session_id: s)

      log =
        capture_log([level: :info], fn ->
          assert BackgroundManager.kill_for_session(s) == 1
          Process.sleep(50)
        end)

      assert log =~ "session ended"
    end
  end
end
