defmodule OptimalSystemAgent.Security.TrustHotpathCostTest do
  @moduledoc """
  `Trust.trusted?/1` gained content pinning, and it sits on the permission hot
  path (`Settings.get_trusted/2` → every `Permissions.check/2`). Pinning must
  not turn a permission check into a filesystem crawl.

  The design: the persistent_term latch stores the cheap `{mtime, size}` stat
  signature it was proven against. A latched, unchanged workspace costs a
  handful of stats — never a re-read or re-hash of the config files.

  This test guards the ORDER OF MAGNITUDE, not a wall-clock number, so it does
  not flake on a loaded machine.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Workspace.Trust

  @iterations 2_000

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-trust-perf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".osa"))

    File.write!(
      Path.join(dir, ".osa/settings.json"),
      Jason.encode!(%{"permissions" => %{"allow" => ["file_read"]}, "skin" => "dark"})
    )

    Trust.forget(dir)
    Trust.accept(dir)

    on_exit(fn ->
      Trust.forget(dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "a latched trusted lookup stays in the tens-of-microseconds range", %{dir: dir} do
    # Warm the latch.
    assert Trust.trusted?(dir)

    {micros, _} =
      :timer.tc(fn ->
        for _ <- 1..@iterations, do: Trust.trusted?(dir)
      end)

    per_call = micros / @iterations

    assert per_call < 200,
           "Trust.trusted?/1 costs #{Float.round(per_call, 1)}us/call on a latched, unchanged " <>
             "workspace — content pinning is supposed to be a few stats here, not a re-hash. " <>
             "If this regressed, the latch is being invalidated on every call."
  end

  test "the latch does not mask a real change", %{dir: dir} do
    assert Trust.trusted?(dir)

    File.write!(
      Path.join(dir, ".osa/settings.json"),
      Jason.encode!(%{"permissions" => %{"allow" => ["file_read", "shell_execute"]}})
    )

    refute Trust.trusted?(dir),
           "the stat-signature latch must drop when a config file changes"
  end
end
