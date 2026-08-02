defmodule OptimalSystemAgent.Scripts.BeamBusyWaitTest do
  @moduledoc """
  Regression tests for issue #66 — the BEAM's schedulers busy-wait before they
  park, which on an idle desktop daemon burns close to one core per scheduler
  thread (853% CPU was reported on a 10-core Mac).

  The remedy is `+sbwt none +sbwtdcpu none +sbwtdio none`, and it has to be in
  place on every path a REAL user's daemon starts from:

    * `rel/env.sh.eex`  — the release env script, sourced before every release
      command. This covers the installed user: `scripts/install.sh`'s launcher,
      the Homebrew formula and `osa serve` all end up at
      `bin/osagent_release eval ...`.
    * `rel/env.bat.eex` — same, for the Windows launcher `scripts/install.ps1`
      drives.
    * `bin/osa`         — the from-source launcher, which starts the daemon with
      `mix osa.serve` and so never runs the release's env.sh.

  The shell blocks are extracted and actually executed, so this tests behaviour
  rather than the presence of a string.
  """
  use ExUnit.Case, async: true

  @flags "+sbwt none +sbwtdcpu none +sbwtdio none"

  @env_sh Path.expand("../../rel/env.sh.eex", __DIR__)
  @env_bat Path.expand("../../rel/env.bat.eex", __DIR__)
  @source_launcher Path.expand("../../bin/osa", __DIR__)

  setup_all do
    unless System.find_executable("sh"), do: raise("sh is required for these tests")
    :ok
  end

  # Everything from the guard down to its closing `fi`.
  defp extract!(path) do
    block =
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, ~s(if [ -z "${OSA_BEAM_BUSY_WAIT))))
      |> Enum.take_while(&(&1 != "fi"))
      |> Kernel.++(["fi"])
      |> Enum.join("\n")

    # Fail loudly if a refactor moved or removed the block, rather than
    # silently running an empty script that passes every assertion.
    assert String.contains?(block, "+sbwt none"),
           "no OSA_BEAM_BUSY_WAIT block found in #{path} — issue #66 guard is gone"

    block
  end

  # Runs the extracted block under `sh` with `env` and echoes back ERL_FLAGS.
  defp erl_flags(block, env) do
    script = block <> "\nprintf '%s' \"${ERL_FLAGS:-}\"\n"
    {out, 0} = System.cmd("sh", ["-c", script], env: env, into: "")
    out
  end

  for {name, path} <- [{"rel/env.sh.eex", @env_sh}, {"bin/osa", @source_launcher}] do
    describe "#{name} busy-wait guard" do
      setup do: {:ok, block: extract!(unquote(path))}

      test "turns scheduler busy-wait off by default", %{block: block} do
        assert erl_flags(block, %{"ERL_FLAGS" => nil, "OSA_BEAM_BUSY_WAIT" => nil}) == @flags
      end

      test "appends to an ERL_FLAGS the user already set", %{block: block} do
        assert erl_flags(block, %{"ERL_FLAGS" => "+K true", "OSA_BEAM_BUSY_WAIT" => nil}) ==
                 "+K true " <> @flags
      end

      test "leaves an explicit +sbwt choice completely alone", %{block: block} do
        assert erl_flags(block, %{"ERL_FLAGS" => "+sbwt very_long", "OSA_BEAM_BUSY_WAIT" => nil}) ==
                 "+sbwt very_long"
      end

      test "OSA_BEAM_BUSY_WAIT=1 restores the stock OTP behaviour", %{block: block} do
        assert erl_flags(block, %{"ERL_FLAGS" => nil, "OSA_BEAM_BUSY_WAIT" => "1"}) == ""
      end
    end
  end

  test "rel/env.bat.eex carries the same flags and the same opt-out" do
    bat = File.read!(@env_bat)
    assert String.contains?(bat, @flags)
    assert String.contains?(bat, "OSA_BEAM_BUSY_WAIT")
  end
end
