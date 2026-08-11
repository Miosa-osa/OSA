defmodule OptimalSystemAgent.Channels.CLI.CommandsDoctorArgsTest do
  @moduledoc """
  `CLI.Doctor.run/1` has always dispatched `--config` to the setup-inspection
  report. The TUI's `/doctor` handler took its args and threw them away,
  calling `run/0` — so in-session `/doctor --config` silently printed the plain
  health report, and the inspection report was reachable only from `osa doctor
  --config` outside a session.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Channels.CLI.Commands

  @health_header "OSA Health Check"
  @inspection_header "OSA Setup Inspection"

  test "/doctor --config reaches the setup-inspection report" do
    out = capture_io(fn -> Commands.cmd_doctor("--config", "sess-1") end)

    assert out =~ @inspection_header,
           "`/doctor --config` must reach the same report `osa doctor --config` does"
  end

  test "/doctor config (bare word) also reaches it" do
    out = capture_io(fn -> Commands.cmd_doctor("config", "sess-1") end)
    assert out =~ @inspection_header
  end

  test "/doctor --all prints both reports" do
    out = capture_io(fn -> Commands.cmd_doctor("--all", "sess-1") end)

    assert out =~ @health_header
    assert out =~ @inspection_header
  end

  test "bare /doctor is unchanged — health report only" do
    out = capture_io(fn -> Commands.cmd_doctor("", "sess-1") end)

    assert out =~ @health_header

    refute out =~ @inspection_header,
           "an empty arg list must take the run/0 branch, leaving bare /doctor as it was"
  end

  test "whitespace-only args behave like bare /doctor" do
    out = capture_io(fn -> Commands.cmd_doctor("   ", "sess-1") end)

    assert out =~ @health_header
    refute out =~ @inspection_header
  end

  test "the session_id is passed through unchanged" do
    capture_io(fn ->
      assert Commands.cmd_doctor("--config", "sess-42") == "sess-42"
    end)
  end
end
