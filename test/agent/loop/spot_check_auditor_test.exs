defmodule OptimalSystemAgent.Agent.Loop.SpotCheckAuditorTest do
  @moduledoc """
  Cheap spot-check tier (VSM System 3* — sporadic, cheap audits). Every
  scenario here is decided WITHOUT spawning a subagent or calling an LLM —
  only local ledger reads, `File.exists?`, and (where explicitly stubbed) a
  bounded command rerun.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.SpotCheckAuditor, as: Auditor
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger
  alias OptimalSystemAgent.Events.Bus

  setup do
    sid = "spot-check-test-" <> Integer.to_string(System.unique_integer([:positive]))
    Ledger.reset(sid)

    dir = Path.join(System.tmp_dir!(), "osa-spot-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Ledger.reset(sid)
      Application.delete_env(:optimal_system_agent, :spot_check_command_runner)
      File.rm_rf(dir)
    end)

    {:ok, sid: sid, dir: dir}
  end

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp record_write(sid, path) do
    Ledger.record(sid, %{tool: "file_edit", args: %{"path" => path}, success: true})
  end

  defp record_check(sid, command, success) do
    Ledger.record(sid, %{tool: "shell_execute", args: %{"command" => command}, success: success})
  end

  defp capture_spot_check_events(sid) do
    test_pid = self()

    ref =
      Bus.register_handler(:system_event, fn payload ->
        data =
          case payload do
            %{data: d} when is_map(d) -> d
            d when is_map(d) -> d
          end

        if data[:event] == :spot_check_audit and data[:session_id] == sid do
          send(test_pid, {:spot_check_event, data})
        end
      end)

    on_exit(fn -> Bus.unregister_handler(:system_event, ref) end)
    ref
  end

  describe "no evidence at all" do
    test "fails closed — cannot vouch for a claim with nothing to sample", %{sid: sid} do
      assert {:fail, reason, report} = Auditor.spot_check(sid)
      assert reason =~ "no evidence"
      assert report.risk == :high
      assert report.checked == []
    end
  end

  describe "the common case this tier exists to make cheap" do
    test "a write covered by a passing check on an existing file PASSES with zero LLM/subagent cost",
         %{sid: sid, dir: dir} do
      path = write_file(dir, "widget.ex", "defmodule Widget do\nend\n")
      record_write(sid, path)
      record_check(sid, "mix compile", true)

      capture_spot_check_events(sid)

      assert {:pass, report} = Auditor.spot_check(sid, diff: "")
      assert report.risk == :low
      assert Enum.any?(report.checked, &(&1.method == :file_exists and &1.result == :confirmed))

      assert_receive {:spot_check_event, %{verdict: :pass}}, 1_000
    end
  end

  describe "ledger-level contradictions (zero extra I/O)" do
    test "a write with NO check covering it fails — pending_files/1 says so for free", %{
      sid: sid,
      dir: dir
    } do
      path = write_file(dir, "untested.ex", "defmodule Untested do\nend\n")
      record_write(sid, path)

      assert {:fail, reason, report} = Auditor.spot_check(sid)
      assert reason =~ "no passing check"
      assert Enum.any?(report.checked, &(&1.method == :ledger_coverage))
    end

    test "the latest check FAILED and was never superseded", %{sid: sid, dir: dir} do
      path = write_file(dir, "red.ex", "defmodule Red do\nend\n")
      record_write(sid, path)
      record_check(sid, "mix compile", false)

      assert {:fail, reason, report} = Auditor.spot_check(sid)
      assert reason =~ "failed"
      assert Enum.any?(report.checked, &(&1.method == :ledger_check))
    end
  end

  describe "direct file-existence check" do
    test "a claimed write to a file that does not exist on disk is CONTRADICTED", %{sid: sid} do
      missing_path = Path.join(System.tmp_dir!(), "definitely-does-not-exist-#{sid}.ex")
      record_write(sid, missing_path)
      record_check(sid, "mix compile", true)

      assert {:fail, reason, report} = Auditor.spot_check(sid)
      assert reason =~ "does not exist"

      assert Enum.any?(
               report.checked,
               &(&1.method == :file_exists and &1.result == :contradicted)
             )
    end
  end

  describe "diff/disk cross-read" do
    test "the diff's added lines are actually present in the file — CONFIRMED", %{
      sid: sid,
      dir: dir
    } do
      path =
        write_file(
          dir,
          "exporter.ex",
          "defmodule Exporter do\n  def run, do: :unique_marker_ok\nend\n"
        )

      record_write(sid, path)
      record_check(sid, "mix compile", true)

      diff = """
      diff --git a/exporter.ex b/exporter.ex
      +defmodule Exporter do
      +  def run, do: :unique_marker_ok
      +end
      """

      assert {:pass, report} = Auditor.spot_check(sid, diff: diff)
      assert Enum.any?(report.checked, &(&1.method == :diff_match and &1.result == :confirmed))
    end

    test "the diff claims content the file does NOT contain — CONTRADICTED (stale/reverted diff)",
         %{sid: sid, dir: dir} do
      path = write_file(dir, "exporter.ex", "defmodule Exporter do\nend\n")
      record_write(sid, path)
      record_check(sid, "mix compile", true)

      diff = """
      diff --git a/exporter.ex b/exporter.ex
      +  def run, do: :this_line_was_never_actually_written
      """

      assert {:fail, reason, _report} = Auditor.spot_check(sid, diff: diff)
      assert reason =~ "stale" or reason =~ "reverted" or reason =~ "does not contain"
    end
  end

  describe "command rerun (injectable, bounded)" do
    test "a rerun that now exits non-zero contradicts the recorded pass", %{sid: sid, dir: dir} do
      path = write_file(dir, "flaky.ex", "defmodule Flaky do\nend\n")
      record_write(sid, path)
      record_check(sid, "mix test flaky_test.exs", true)

      Application.put_env(:optimal_system_agent, :spot_check_command_runner, fn _cmd ->
        {:ok, 1}
      end)

      assert {:fail, reason, report} = Auditor.spot_check(sid, allow_rerun?: true)
      assert reason =~ "exited 1"
      assert Enum.any?(report.checked, &(&1.method == :rerun and &1.result == :contradicted))
    end

    test "allow_rerun?: false never invokes the runner", %{sid: sid, dir: dir} do
      path = write_file(dir, "ok.ex", "defmodule Ok do\nend\n")
      record_write(sid, path)
      record_check(sid, "mix test ok_test.exs", true)

      test_pid = self()

      Application.put_env(:optimal_system_agent, :spot_check_command_runner, fn cmd ->
        send(test_pid, {:rerun_called, cmd})
        {:ok, 0}
      end)

      assert {:pass, _report} = Auditor.spot_check(sid, allow_rerun?: false)
      refute_receive {:rerun_called, _}, 100
    end
  end

  describe "risk escalation independent of any contradiction" do
    test "a security-sensitive path escalates even when every sampled check confirms", %{
      sid: sid,
      dir: dir
    } do
      path = write_file(dir, "auth_token.ex", "defmodule AuthToken do\nend\n")
      record_write(sid, path)
      record_check(sid, "mix compile", true)

      assert {:fail, reason, report} = Auditor.spot_check(sid)
      assert report.risk == :high
      assert reason =~ "sensitive" or reason =~ "security"
    end

    test "a large, untested change with no acceptance criteria escalates", %{sid: sid, dir: dir} do
      # `file_write` (not an in-place edit tool) => `:whole_file` edit shape =>
      # `change_scale/1` reads it as :large. No check at all was recorded, so
      # `needs_discriminating_test?/1` is true, and no criteria is passed.
      path = Path.join(dir, "big_module.ex")
      File.write!(path, "defmodule BigModule do\nend\n")
      Ledger.record(sid, %{tool: "file_write", args: %{"path" => path}, success: true})
      record_check(sid, "mix compile", true)

      assert {:fail, _reason, report} = Auditor.spot_check(sid, criteria: "")
      assert report.risk == :high
    end
  end

  describe "cap" do
    test "never samples more than :max_samples claims", %{sid: sid, dir: dir} do
      for n <- 1..10 do
        path = write_file(dir, "file_#{n}.ex", "defmodule File#{n} do\nend\n")
        record_write(sid, path)
      end

      record_check(sid, "mix compile", true)

      {_verdict, _reason_or_report, report} =
        case Auditor.spot_check(sid, max_samples: 2) do
          {:pass, r} -> {:pass, nil, r}
          {:fail, reason, r} -> {:fail, reason, r}
        end

      file_checks = Enum.filter(report.checked, &(&1.method == :file_exists))
      assert length(file_checks) <= 2
    end
  end
end
