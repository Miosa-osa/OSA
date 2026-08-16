defmodule OptimalSystemAgent.Tools.FileGrepBoundsItsSubprocessTest do
  @moduledoc """
  One wedged `rg` must not take the session with it.

  `file_grep` called `System.cmd("rg", …)` with no timeout and no wrapper.
  `System.cmd/3` has no deadline of its own, the tool Task it runs in has none
  either (`:tool_timeout_ms` is `:infinity` by design — see
  `LongRunningToolTest`), and `Agent.Loop` runs the whole turn on its own stack.
  So a `rg` that never returned wedged the turn, and the session with it, until
  the 24-hour `GenServer.call` backstop.

  `rg` blocking is not exotic: reading a FIFO with no writer, a dead NFS/SSHFS
  mount, or a `/proc` pseudo-file all do it, and a broad `path` walks into them
  by accident.

  Every other tool that shells out already bounds its own subprocess
  (`shell_execute` 120s, `web_fetch` 30s, `github` 30s). This bound brings
  `file_grep` in line with that design. It bounds ONE subprocess — not the tool
  call, not the turn, not the session — and on expiry the tool says so. It does
  NOT fall through to the pure-Elixir fallback, because answering a search that
  hung with a plausible-looking result is the silent wrong answer this module
  has been burned by before.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileGrep.Handler

  setup do
    prev_path = System.get_env("PATH")
    prev_timeout = Application.get_env(:optimal_system_agent, :file_grep_timeout_ms)

    # A fake `rg` that hangs, first on PATH. This is the real failure — the
    # binary runs and never returns — rather than a mocked-out call.
    bin_dir = Path.join(System.tmp_dir!(), "fg-hang-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin_dir)
    fake_rg = Path.join(bin_dir, "rg")
    File.write!(fake_rg, "#!/bin/sh\nsleep 120\n")
    File.chmod!(fake_rg, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> prev_path)

    search_dir = Path.join(System.tmp_dir!(), "fg-target-#{System.unique_integer([:positive])}")
    File.mkdir_p!(search_dir)
    File.write!(Path.join(search_dir, "a.txt"), "needle\n")

    on_exit(fn ->
      System.put_env("PATH", prev_path)
      File.rm_rf(bin_dir)
      File.rm_rf(search_dir)

      if prev_timeout,
        do: Application.put_env(:optimal_system_agent, :file_grep_timeout_ms, prev_timeout),
        else: Application.delete_env(:optimal_system_agent, :file_grep_timeout_ms)
    end)

    {:ok, search_dir: search_dir}
  end

  test "a ripgrep that never returns is stopped, and the tool says so", %{search_dir: dir} do
    Application.put_env(:optimal_system_agent, :file_grep_timeout_ms, 700)

    started = System.monotonic_time(:millisecond)
    result = Handler.execute(%{"pattern" => "needle", "path" => dir}, %{})
    elapsed = System.monotonic_time(:millisecond) - started

    # The bound is real. Without it this call blocks for the fake rg's full 120s
    # (and forever, for a real wedge).
    assert elapsed < 30_000,
           "file_grep did not bound its subprocess: it ran for #{elapsed}ms"

    assert {:error, message} = result

    # ATTRIBUTABLE: names the tool, so the failure is not anonymous.
    assert message =~ "file_grep",
           "the failure must name the tool it belongs to: #{inspect(message)}"

    # REPORTED as an incomplete search, not as an absence of matches. This is
    # the load-bearing half: "No matches found." for a search that never ran
    # sends the model down a false trail.
    assert message =~ ~r/not\s+be\s+completed|NOT\s+completed/i,
           "the model must be told the search did not finish: #{inspect(message)}"

    refute message =~ "No matches found",
           "a hung search must never be reported as a completed empty search"
  end

  test "the wedged ripgrep is actually REAPED, not just abandoned", %{search_dir: dir} do
    # The bound freed the turn from the start. It did not free the machine: the
    # original fix ran `System.cmd/3` in a task and `:brutal_kill`ed the task,
    # and its comment claimed "closing a Port kills the OS process it owns".
    # Measured with `ps`, that claim was false — the `rg` survived its own
    # deadline, reparented to init, still holding whatever wedged it, one orphan
    # per wedged search for the life of the session.
    #
    # `ps` is the evidence here for the same reason it was the evidence that
    # exposed the bug: the BEAM's view of a port says nothing about whether the
    # OS process is still running.
    marker = "osa-fg-reap-#{System.unique_integer([:positive])}"

    bin_dir = Path.join(System.tmp_dir!(), "fg-reap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin_dir)
    fake_rg = Path.join(bin_dir, "rg")

    # A shell that forks a GRANDCHILD and waits on it. This is the shape that
    # actually leaks — signalling only the direct child leaves the grandchild
    # running — and it is what a real `rg` piping into a pager, or any wrapper
    # script, looks like to the kernel.
    File.write!(fake_rg, "#!/bin/sh\nsleep 120 # #{marker} &\nsleep 120 # #{marker}\n")
    File.chmod!(fake_rg, 0o755)

    prev_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> prev_path)
    Application.put_env(:optimal_system_agent, :file_grep_timeout_ms, 700)

    on_exit(fn ->
      System.put_env("PATH", prev_path)
      File.rm_rf(bin_dir)
    end)

    assert {:error, _} = Handler.execute(%{"pattern" => "needle", "path" => dir}, %{})

    # TERM, grace, KILL, then the kernel reaps the zombie.
    Process.sleep(500)
    {ps_out, _} = System.cmd("ps", ["-eo", "pid,stat,args"], stderr_to_stdout: true)

    survivors =
      ps_out
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, marker))
      |> Enum.reject(&String.contains?(&1, "<defunct>"))
      |> Enum.reject(&String.contains?(&1, "ps -eo"))

    assert survivors == [],
             "the wedged ripgrep outlived its deadline as an orphan:\n" <>
               Enum.join(survivors, "\n")
  end

  test "the bound does not fire on a search that answers normally", %{search_dir: dir} do
    # Same fixture, same code path, a fake `rg` that behaves. Guards against a
    # bound so tight (or a branch so eager) that it reports healthy searches as
    # wedged — the failure mode that would make this worse than no bound at all.
    bin_dir = Path.join(System.tmp_dir!(), "fg-fast-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin_dir)
    fake_rg = Path.join(bin_dir, "rg")
    # Exit 1 = "no match", ripgrep's own vocabulary for an answered search.
    File.write!(fake_rg, "#!/bin/sh\nexit 1\n")
    File.chmod!(fake_rg, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> System.get_env("PATH"))
    on_exit(fn -> File.rm_rf(bin_dir) end)

    Application.put_env(:optimal_system_agent, :file_grep_timeout_ms, 30_000)

    assert {:ok, output} = Handler.execute(%{"pattern" => "needle", "path" => dir}, %{})

    refute output =~ "did not finish",
           "a search that completed must not be reported as wedged: #{inspect(output)}"
  end

  test "the shipped default is generous, and disablable" do
    Application.delete_env(:optimal_system_agent, :file_grep_timeout_ms)

    default = OptimalSystemAgent.Tools.Builtins.FileGrep.Constants.ripgrep_timeout_ms()

    assert default >= 60_000,
           "a tight default would kill legitimate searches over large trees: #{default}"

    # An operator who wants the old unbounded behaviour can still have it.
    Application.put_env(:optimal_system_agent, :file_grep_timeout_ms, :infinity)

    assert OptimalSystemAgent.Tools.Builtins.FileGrep.Constants.ripgrep_timeout_ms() == :infinity
  end
end
