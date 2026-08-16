defmodule OptimalSystemAgent.LifecycleStage3Test do
  @moduledoc """
  Stage 3/3 lifecycle backend: `osa doctor` (structured report + real checks),
  `osa version`/version-check, and the `/release-notes` CHANGELOG resource.

  All tests are deterministic and offline — the doctor checks and version probe
  degrade gracefully (git/network absent is fine), so nothing here dials out.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.CLI.Doctor
  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.ReleaseNotes

  # ── ReleaseNotes: changelog resource ─────────────────────────────────

  describe "ReleaseNotes changelog resource" do
    test "a changelog resource is bundled and parses into entries" do
      assert ReleaseNotes.changelog_path() != nil
      entries = ReleaseNotes.entries()
      assert is_list(entries)
      assert length(entries) > 0

      first = List.first(entries)
      assert is_binary(first.version)
      assert is_binary(first.body)
      assert Map.has_key?(first, :date)
    end

    test "latest/0 returns the newest entry" do
      latest = ReleaseNotes.latest()
      assert latest == List.first(ReleaseNotes.entries())
    end

    test "latest_text/1 returns a non-empty string capped to n entries" do
      text = ReleaseNotes.latest_text(1)
      assert is_binary(text)
      assert text != ""

      two = ReleaseNotes.latest_text(2)
      assert byte_size(two) >= byte_size(text)
    end
  end

  # ── ReleaseNotes: version-check ──────────────────────────────────────

  describe "ReleaseNotes version-check" do
    test "current_version/0 returns a version string" do
      v = ReleaseNotes.current_version()
      assert is_binary(v)
      assert v != ""
    end

    test "version_status/0 reports current, latest, and update_available" do
      status = ReleaseNotes.version_status()
      assert %{current: current, latest: latest, update_available: avail} = status
      assert is_binary(current)
      assert is_binary(latest)
      assert is_boolean(avail)
    end

    test "version_newer?/2 compares semver correctly" do
      assert ReleaseNotes.version_newer?("1.2.0", "1.1.9")
      assert ReleaseNotes.version_newer?("v0.5.0", "0.4.6")
      refute ReleaseNotes.version_newer?("1.0.0", "1.0.0")
      refute ReleaseNotes.version_newer?("0.4.0", "0.5.0")
      refute ReleaseNotes.version_newer?("garbage", "1.0.0")
    end
  end

  # ── Doctor: structured report ────────────────────────────────────────

  describe "Doctor.report/0" do
    test "returns a JSON-friendly structured report" do
      report = Doctor.report()

      assert %{ready: ready, status: status, failed: failed, checks: checks} = report
      assert is_boolean(ready)
      assert status in ["ready", "not_ready"]
      assert is_integer(failed) and failed >= 0
      assert is_list(checks) and length(checks) > 0
    end

    test "each check has name, string status, and detail" do
      for c <- Doctor.report().checks do
        assert is_binary(c.name)
        assert c.status in ["pass", "fail", "optional"]
        assert is_binary(c.detail)
      end
    end

    test "ready flag agrees with failed count" do
      %{ready: ready, failed: failed} = Doctor.report()
      assert ready == (failed == 0)
    end

    test "report includes the real wired checks (runtime, version, config)" do
      names = Doctor.report().checks |> Enum.map(& &1.name) |> MapSet.new()
      assert "Runtime" in names
      assert "Version" in names
      assert "Config" in names
    end

    test "checks/0 is encodable to JSON via report/0" do
      assert {:ok, json} = Jason.encode(Doctor.report())
      assert is_binary(json)
    end
  end

  # ── CLI commands: /version and /release-notes ────────────────────────

  describe "lifecycle slash commands" do
    test "commands are registered in the unified registry" do
      names = Commands.list_with_descriptions() |> Enum.map(&elem(&1, 0))
      assert "version" in names
      assert "release-notes" in names
      assert "doctor" in names
    end

    test "/version prints the version and a check line, returns session_id" do
      out = capture_io(fn -> assert "s1" = Commands.dispatch("version", "s1") end)
      assert out =~ "OSA"
      assert out =~ "v#{ReleaseNotes.current_version()}"

      # `cmd_version/2` has THREE outcomes, and the third is the whole point of
      # the code it guards: `version_status/0` answers `:unknown` when nothing
      # local is authoritative, precisely so an install with nothing to compare
      # against stops reporting itself as current. This test asserted only two
      # of them, so it was really asserting "this checkout has git tags".
      #
      # `actions/checkout` fetches none by default, so `latest_release_tag/0`
      # returned nil on CI, `classify/3` correctly refused to conclude
      # `:current` from the bundled changelog, and the honest third sentence
      # printed — failing a test that had no row for it. It passed here only
      # because a developer's clone carries the tags.
      #
      # So the line is matched against the status actually reported, which is
      # stronger than the original disjunction rather than weaker: a missing
      # line, or the wrong sentence for the reported status, still fails.
      expected =
        case ReleaseNotes.version_status() do
          %{status: :update_available} -> "available"
          %{status: :current} -> "up to date"
          %{status: :unknown} -> "could not check for updates"
        end

      assert out =~ expected
    end

    test "/release-notes prints the what's-new section, returns session_id" do
      out = capture_io(fn -> assert "s2" = Commands.dispatch("release-notes", "s2") end)
      assert out =~ "What's New"
    end

    test "/doctor runs the health check without raising" do
      out = capture_io(fn -> assert "s3" = Commands.dispatch("doctor", "s3") end)
      assert out =~ "OSA Health Check"
      refute out =~ "doctor not available"
    end
  end
end
