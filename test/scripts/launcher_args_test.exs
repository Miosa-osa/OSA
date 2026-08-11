defmodule OptimalSystemAgent.Scripts.LauncherArgsTest do
  @moduledoc """
  Regression tests for the `osa` launcher's subcommand handling, exercised by
  actually running the shell.

  `scripts/install.sh` writes the launcher as a heredoc, so the argument-handling
  block is extracted out of it and run standalone. Two things are under test:

    * `osa resume <id>` is translated into the `--resume <id>` flag the TUI
      already parses (one parser, not two).
    * The verb is recognised WHEREVER it sits, so mode flags may come before it
      (`osa --overdrive resume <id>`) — while a flag's VALUE is never mistaken
      for a verb (`osa --model resume`).
  """
  use ExUnit.Case, async: true

  @launcher Path.expand("../../scripts/install.sh", __DIR__)

  # Everything between the scan header and the dispatch `case`: the verb scan
  # plus the verb→flag translation. (The `opencomputers` guard above it is a
  # positional passthrough with no argument rewriting, so it is out of scope.)
  @start_marker "# ── Subcommand scan"
  @end_marker "# ── Subcommand dispatch"

  setup_all do
    unless System.find_executable("bash"), do: raise("bash is required for these tests")

    source = File.read!(@launcher)

    [_, block] = String.split(source, @start_marker, parts: 2)
    [block, _] = String.split(block, @end_marker, parts: 2)

    # Fail loudly if a refactor moved the markers, rather than silently testing
    # an empty script that passes every assertion.
    assert String.contains?(block, "OSA_VERB")
    assert String.contains?(block, "--resume")

    dir =
      System.tmp_dir!() |> Path.join("osa-launcher-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    harness = Path.join(dir, "harness.sh")

    File.write!(harness, """
    #!/usr/bin/env bash
    set -eu
    RELEASE_BIN=/bin/true
    # #{block}
    printf 'verb=%s overdrive=%s args=%s\\n' "$OSA_VERB" "$OVERDRIVE" "$*"
    """)

    {:ok, harness: harness}
  end

  # `bin/osa` is the from-source launcher — the one `osa` on PATH actually
  # forwards to during development — and carries its own copy of the verb
  # translation. Only the three LAUNCH verbs are scanned position-independently
  # there; `update`/`remote`/`opencomputers` keep their `$1`-only dispatch.
  @source_launcher Path.expand("../../bin/osa", __DIR__)
  @src_start "# ── Launch-verb pre-translation"
  @src_end "# Any explicit full-auto flag"

  setup_all do
    source = File.read!(@source_launcher)
    [_, block] = String.split(source, @src_start, parts: 2)
    [block, _] = String.split(block, @src_end, parts: 2)
    assert String.contains?(block, "_verb")
    assert String.contains?(block, "--resume")

    dir = System.tmp_dir!() |> Path.join("osa-src-launcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    harness = Path.join(dir, "src_harness.sh")

    File.write!(harness, """
    #!/usr/bin/env bash
    set -eu
    # #{block}
    printf 'verb=%s overdrive=%s args=%s\\n' "$_verb" "$OVERDRIVE" "$*"
    """)

    {:ok, src_harness: harness}
  end

  describe "bin/osa (the from-source launcher)" do
    test "resume works with flags on either side", %{src_harness: h} do
      assert run(h, ["resume", "abc"])["args"] == "--resume abc"
      assert run(h, ["--overdrive", "resume", "abc"])["args"] == "--overdrive --resume abc"
      assert run(h, ["resume", "abc", "--overdrive"])["args"] == "--overdrive --resume abc"

      assert run(h, ["--profile", "work", "resume", "abc"])["args"] ==
               "--profile work --resume abc"
    end

    test "bare resume opens the picker", %{src_harness: h} do
      assert run(h, ["resume"])["args"] == "--resume"
    end

    test "a flag value named resume is not a verb", %{src_harness: h} do
      assert run(h, ["--model", "resume"])["verb"] == ""
      assert run(h, ["--model", "resume"])["args"] == "--model resume"
    end

    test "non-launch subcommands are left for the positional dispatch", %{src_harness: h} do
      # These must reach `case "${1:-}"` untouched, or `osa update --staged`
      # and `osa remote list` would lose their own arguments.
      for argv <- [["update", "--staged"], ["remote", "list"], ["version"], ["doctor"]] do
        r = run(h, argv)
        assert r["verb"] == "", inspect(argv)
        assert r["args"] == Enum.join(argv, " "), inspect(argv)
      end
    end

    test "overdrive and continue still translate", %{src_harness: h} do
      assert run(h, ["overdrive"])["args"] == "--overdrive"
      assert run(h, ["--dev", "continue"])["args"] == "--dev --continue"
    end
  end

  defp run(harness, args) do
    {out, 0} = System.cmd("bash", [harness | args], stderr_to_stdout: true)

    Regex.named_captures(
      ~r/verb=(?<verb>\S*) overdrive=(?<overdrive>\d) args=(?<args>.*)/,
      String.trim(out)
    )
  end

  describe "the resume subcommand" do
    test "forwards the id as --resume <id>", %{harness: h} do
      r = run(h, ["resume", "abc123"])
      assert r["verb"] == "resume"
      assert r["args"] == "--resume abc123"
    end

    test "with no id becomes a bare --resume (the session picker)", %{harness: h} do
      r = run(h, ["resume"])
      assert r["verb"] == "resume"
      assert r["args"] == "--resume"
    end

    test "does not swallow a following flag as the id", %{harness: h} do
      r = run(h, ["resume", "--dev"])
      assert r["args"] == "--dev --resume"
    end
  end

  describe "flags compose with the subcommand in BOTH orders" do
    test "osa resume <id> --overdrive", %{harness: h} do
      r = run(h, ["resume", "abc123", "--overdrive"])
      assert r["verb"] == "resume"
      assert r["overdrive"] == "1"
      assert r["args"] =~ "--overdrive"
      assert r["args"] =~ "--resume abc123"
    end

    test "osa --overdrive resume <id> — the flag BEFORE the verb", %{harness: h} do
      r = run(h, ["--overdrive", "resume", "abc123"])
      assert r["verb"] == "resume"
      assert r["overdrive"] == "1"
      assert r["args"] == "--overdrive --resume abc123"
    end

    test "every overdrive alias is recognised before the verb", %{harness: h} do
      for alias_flag <- ["--overdrive", "--yolo", "--dangerously-skip-permissions"] do
        r = run(h, [alias_flag, "resume", "s"])
        assert r["verb"] == "resume", alias_flag
        assert r["overdrive"] == "1", alias_flag
      end
    end

    test "--permission-mode before the verb keeps its value", %{harness: h} do
      r = run(h, ["--permission-mode", "plan", "resume", "abc"])
      assert r["args"] == "--permission-mode plan --resume abc"
    end

    test "--profile / --model / --provider all survive", %{harness: h} do
      r = run(h, ["--profile", "work", "resume", "abc", "--model", "m", "--provider", "p"])
      assert r["verb"] == "resume"
      assert r["args"] =~ "--profile work"
      assert r["args"] =~ "--model m"
      assert r["args"] =~ "--provider p"
      assert r["args"] =~ "--resume abc"
    end
  end

  describe "a flag's VALUE is never a subcommand" do
    test "osa --model resume launches normally with a model named resume", %{harness: h} do
      r = run(h, ["--model", "resume"])
      assert r["verb"] == ""
      assert r["args"] == "--model resume"
    end

    test "a real verb after a flag value is still found", %{harness: h} do
      r = run(h, ["--model", "resume", "resume", "abc"])
      assert r["verb"] == "resume"
      assert r["args"] == "--model resume --resume abc"
    end

    test "osa --profile resume is a profile, not a verb", %{harness: h} do
      r = run(h, ["--profile", "resume"])
      assert r["verb"] == ""
    end
  end

  describe "the pre-existing verbs still work" do
    test "continue translates to --continue, in either order", %{harness: h} do
      assert run(h, ["continue"])["args"] == "--continue"
      assert run(h, ["--dev", "continue"])["args"] == "--dev --continue"
    end

    test "overdrive sets the mode and the flag", %{harness: h} do
      r = run(h, ["overdrive"])
      assert r["overdrive"] == "1"
      assert r["args"] == "--overdrive"
    end

    test "update is stripped so the remaining flags launch cleanly", %{harness: h} do
      r = run(h, ["update", "--dev"])
      assert r["verb"] == "update"
      assert r["args"] == "--dev"
    end

    test "help / version are recognised as verbs and as flags", %{harness: h} do
      assert run(h, ["help"])["verb"] == "help"
      assert run(h, ["--help"])["verb"] == "help"
      assert run(h, ["version"])["verb"] == "version"
      assert run(h, ["-V"])["verb"] == "version"
    end

    test "stop, setup, serve, doctor are recognised", %{harness: h} do
      for verb <- ["stop", "setup", "serve", "doctor"] do
        assert run(h, [verb])["verb"] == verb
      end
    end
  end

  describe "non-verbs are left alone for the TUI to reject" do
    test "an unknown bare token is not consumed", %{harness: h} do
      r = run(h, ["bogus"])
      assert r["verb"] == ""
      assert r["args"] == "bogus"
    end

    test "a bare -- ends the scan", %{harness: h} do
      r = run(h, ["--", "--raw"])
      assert r["verb"] == ""
      assert r["args"] == "-- --raw"
    end

    test "plain flags with no verb launch normally", %{harness: h} do
      r = run(h, ["--dev", "--no-color"])
      assert r["verb"] == ""
      assert r["args"] == "--dev --no-color"
    end
  end
end
