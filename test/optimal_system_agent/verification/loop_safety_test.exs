defmodule OptimalSystemAgent.Verification.LoopSafetyTest do
  @moduledoc """
  Two ways the verification loop could run shell nobody asked for.

  1. `apply_fix/1` took every line of the LLM's answer starting `"$ "` and
     handed it straight to `OS.Shell.cmd/2` — no allowlist, no circuit breaker,
     no permission check, and the loop runs unattended.

  2. The result guard was `is_reference(ref) and ref == state.task_ref` with no
     status check, and `escalate/2` cleared neither `task_ref` nor the in-flight
     task. So after an `:overall_timeout` escalation the test task's late result
     still matched, flipped the verdict, overwrote the checkpoint, and on the
     failing branch reached `apply_fix/1` and ran MORE shell.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Verification.Loop

  defp await_terminal(loop_id, deadline_ms \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_terminal(loop_id, deadline)
  end

  defp do_await_terminal(loop_id, deadline) do
    case Loop.get_state(loop_id) do
      {:ok, %{status: status} = snap} when status != :running ->
        {:ok, snap}

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, other}
        else
          Process.sleep(25)
          do_await_terminal(loop_id, deadline)
        end
    end
  end

  describe "gate_fix_command/1 — model-authored shell is not trusted" do
    test "refuses a command with no matching allow rule" do
      # `Permissions.check_detailed/2` defaults to `:ask` when nothing matches.
      # Unattended, `:ask` can only mean refuse.
      assert {:refused, reason} = Loop.gate_fix_command("mix format")
      assert reason =~ "requires approval"
    end

    test "refuses a circuit-breaker command outright" do
      assert {:refused, reason} = Loop.gate_fix_command("rm -rf /")
      assert reason =~ "circuit breaker"
    end

    test "refuses an empty command" do
      assert {:refused, _} = Loop.gate_fix_command("   ")
    end

    test "allows a command the operator explicitly allowed" do
      flag_file =
        Path.join(System.tmp_dir!(), "osa-vloop-gate-#{System.unique_integer([:positive])}.json")

      prior = Application.get_env(:optimal_system_agent, :settings_flag_path)

      File.write!(
        flag_file,
        Jason.encode!(%{
          "permissions" => %{"allow" => ["shell_execute(echo verification-ok)"]}
        })
      )

      Application.put_env(:optimal_system_agent, :settings_flag_path, flag_file)
      Settings.reset_cache()

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
          path -> Application.put_env(:optimal_system_agent, :settings_flag_path, path)
        end

        File.rm(flag_file)
        Settings.reset_cache()
      end)

      assert Loop.gate_fix_command("echo verification-ok") == :allow
    end
  end

  describe "a terminated loop refuses late results" do
    test "a result arriving after an :overall_timeout escalation cannot flip the verdict" do
      loop_id = "vloop-late-#{System.unique_integer([:positive])}"

      marker =
        Path.join(System.tmp_dir!(), "osa_vloop_late_#{System.unique_integer([:positive])}")

      # The command outlives the overall timeout, so `escalate/2` fires while the
      # task is still running — the exact race. It then exits 0, which the old
      # guard accepted and turned into `succeed/1`.
      {:ok, _pid} =
        Loop.start_link(
          loop_id: loop_id,
          test_command: "sleep 2; touch #{marker}; exit 0",
          max_iterations: 5,
          timeout_ms: 300
        )

      assert {:ok, snap} = await_terminal(loop_id, 5_000)
      assert snap.status == :escalated

      # Well past the point where the late {ref, {:test_result, 0, _}} would land.
      Process.sleep(3_000)

      assert {:ok, after_snap} = Loop.get_state(loop_id)

      assert after_snap.status == :escalated,
             "a late test result rewrote a terminal verdict to :#{after_snap.status}"

      File.rm(marker)
    end

    test "an escalated loop ignores a stray late result message" do
      loop_id = "vloop-stray-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Loop.start_link(
          loop_id: loop_id,
          test_command: "exit 3",
          max_iterations: 1,
          timeout_ms: 30_000
        )

      assert {:ok, snap} = await_terminal(loop_id)
      assert snap.status == :escalated

      send(pid, {make_ref(), {:test_result, 0, "late pass"}})
      Process.sleep(200)

      assert {:ok, %{status: :escalated}} = Loop.get_state(loop_id)
    end
  end
end
