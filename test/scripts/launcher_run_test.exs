defmodule OptimalSystemAgent.Scripts.LauncherRunTest do
  @moduledoc """
  `osa run` reaches the headless agent from every launcher, never the TUI.

  v1.0.208's installed launcher had no `run` verb: it handed `run` to the TUI,
  which rejected it, and every MIOSA OSA run failed. The blocks under test are
  extracted from the real scripts and run with bash, like `LauncherArgsTest`.
  """
  use ExUnit.Case, async: true

  @install Path.expand("../../scripts/install.sh", __DIR__)
  @source_launcher Path.expand("../../bin/osa", __DIR__)
  @mix_exs Path.expand("../../mix.exs", __DIR__)

  @moduletag :tmp_dir

  defp block(path, from, to) do
    [_, rest] = String.split(File.read!(path), from, parts: 2)
    [body, _] = String.split(rest, to, parts: 2)
    body
  end

  defp bash(script, args, env \\ []) do
    System.cmd("bash", ["-c", script, "osa" | args], env: env, stderr_to_stdout: true)
  end

  describe "installed launcher (scripts/install.sh)" do
    setup %{tmp_dir: dir} do
      scan = block(@install, "# ── --no-onboarding ──", "# ── Subcommand dispatch")
      assert scan =~ "OSA_VERB"

      harness = """
      set -eu
      RELEASE_BIN=/bin/true
      # #{scan}
      printf 'verb=%s skip=%s args=%s\\n' "$OSA_VERB" "${OSA_SKIP_ONBOARDING:-}" "$*"
      """

      path = Path.join(dir, "scan.sh")
      File.write!(path, harness)
      {:ok, harness: File.read!(path)}
    end

    defp scan(harness, args) do
      {out, 0} = bash(harness, args)
      String.trim(out)
    end

    test "run is a verb, and everything after it is passed through untouched", %{harness: h} do
      assert scan(h, ~w(run --format stream-json --model m --overdrive --resume abc)) ==
               "verb=run skip= args=--format stream-json --model m --overdrive --resume abc"
    end

    test "a prompt word that is also a verb stays a prompt word", %{harness: h} do
      assert scan(h, ~w(run resume the task)) == "verb=run skip= args=resume the task"
    end

    test "flags before run are kept", %{harness: h} do
      assert scan(h, ~w(--overdrive run --format json)) ==
               "verb=run skip= args=--overdrive --format json"
    end

    test "a flag value named run is not the verb", %{harness: h} do
      assert scan(h, ~w(--model run)) == "verb= skip= args=--model run"
    end

    test "--no-onboarding is consumed anywhere and exported", %{harness: h} do
      assert scan(h, ~w(--no-onboarding)) == "verb= skip=1 args="
      assert scan(h, ~w(resume abc --no-onboarding)) == "verb=resume skip=1 args=--resume abc"
    end

    test "run dispatches to the release before the headless-install guard and the TUI" do
      source = File.read!(@install)
      dispatch = block(@install, "# ── Subcommand dispatch", "# Headless hosts must not warm")
      assert dispatch =~ ~s(run\)                  exec "$RELEASE_BIN" run "$@" ;;)
      # In the launcher heredoc, `run` is dispatched before the final TUI exec.
      launcher = source |> String.split("<<'LAUNCHER_EOF'\n") |> List.last()
      {run_at, _} = :binary.match(launcher, ~s(exec "$RELEASE_BIN" run "$@"))
      {tui_at, _} = :binary.match(launcher, ~s(exec "$TUI_BIN" "$@"\nLAUNCHER_EOF))
      assert run_at < tui_at
    end

    test "a launcher reached through a symlink finds the release next to itself", %{
      tmp_dir: dir
    } do
      fallback =
        block(
          @install,
          "# The release lives next to THIS launcher",
          "if [ ! -x \"$RELEASE_BIN\" ]; then\n  echo \"OSA is not installed"
        )

      install = Path.join(dir, "desktop/.osa")
      File.mkdir_p!(Path.join(install, "release/bin"))
      File.mkdir_p!(Path.join(install, "bin"))
      release = Path.join(install, "release/bin/osagent")
      File.write!(release, "#!/bin/sh\n")
      File.chmod!(release, 0o755)

      launcher = Path.join(install, "bin/osa")

      File.write!(launcher, """
      #!/usr/bin/env bash
      set -eu
      OSA_HOME='#{Path.join(dir, "sandbox/.osa")}'
      RELEASE_BIN="$OSA_HOME/release/bin/osagent"
      TUI_BIN="$OSA_HOME/bin/osagent-tui"
      # #{fallback}
      echo "$RELEASE_BIN"
      """)

      File.chmod!(launcher, 0o755)
      link = Path.join(dir, "osa-link")
      File.ln_s!(launcher, link)

      {out, 0} = System.cmd(link, [])
      assert String.trim(out) == Path.join(install, "release/bin/osagent") |> resolve()
    end
  end

  describe "release wrapper (bin/osagent, written by mix.exs)" do
    test "run evaluates the headless entry point with argv, events on fd 3" do
      wrapper = File.read!(@mix_exs)
      [_, run] = String.split(wrapper, "      run)\n", parts: 2)
      [run, _] = String.split(run, ";;", parts: 2)

      assert run =~ "exec 3>&1 1>&2"
      assert run =~ "export OSA_EVENT_FD=3"

      assert run =~
               ~s(exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.Headless.main(System.argv\(\)\)" "$@")
    end
  end

  describe "source launcher (bin/osa)" do
    test "run execs mix osa.run with its args, events on the real stdout", %{tmp_dir: dir} do
      run_block =
        block(@source_launcher, "# ── osa run: the headless agent", "# ── --no-onboarding")

      fake_bin = Path.join(dir, "bin")
      File.mkdir_p!(fake_bin)
      mix = Path.join(fake_bin, "mix")

      File.write!(mix, """
      #!/bin/sh
      echo "compile noise"
      printf 'cwd=%s fd=%s args=%s\\n' "$(pwd)" "$OSA_EVENT_FD" "$*" >&3
      """)

      File.chmod!(mix, 0o755)
      root = Path.join(dir, "root")
      File.mkdir_p!(root)

      script = """
      set -eu
      ROOT='#{root}'
      # #{run_block}
      echo "fell through"
      """

      {out, 0} =
        System.cmd("bash", ["-c", script, "osa", "run", "--format", "stream-json"],
          env: [{"PATH", fake_bin <> ":" <> System.get_env("PATH")}]
        )

      assert String.trim(out) ==
               "cwd=#{resolve(root)} fd=3 args=osa.run --format stream-json"
    end

    test "run is dispatched before workspace auto-isolation can move OSA_HOME" do
      source = File.read!(@source_launcher)
      {run_at, _} = :binary.match(source, "# ── osa run: the headless agent")
      {isolation_at, _} = :binary.match(source, "# ── Auto-isolation by working directory")
      assert run_at < isolation_at
    end
  end

  defp resolve(path) do
    {out, 0} =
      System.cmd("sh", [
        "-c",
        "cd \"$(dirname \"$1\")\" && echo \"$(pwd -P)/$(basename \"$1\")\"",
        "sh",
        path
      ])

    String.trim(out)
  end
end
