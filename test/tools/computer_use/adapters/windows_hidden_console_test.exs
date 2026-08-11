defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.WindowsHiddenConsoleTest do
  @moduledoc """
  Every Windows keystroke, key combo and clipboard write used to run through
  `System.cmd/3`, which gives Erlang no way to suppress the console window: a
  PowerShell console flashed up and STOLE FOCUS, so the SendKeys payload landed
  in whatever window grabbed focus instead of the intended target.

  The console itself can only be observed on Windows. What is asserted here is
  the mechanism: the adapter spawns through a Port with `:hide` (CREATE_NO_WINDOW
  on Windows, a no-op elsewhere) and still collects output and exit status
  correctly.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.Windows

  describe "port_opts/1" do
    test "always requests a hidden console" do
      assert :hide in Windows.port_opts()
      assert :hide in Windows.port_opts(merge_stderr: false)
    end

    test "merges stderr only when asked" do
      assert :stderr_to_stdout in Windows.port_opts(merge_stderr: true)
      refute :stderr_to_stdout in Windows.port_opts(merge_stderr: false)
    end
  end

  describe "run_hidden/3" do
    @describetag :unix

    test "collects stdout and reports success" do
      assert {:ok, out} = Windows.run_hidden("/bin/echo", ["typed-ok"])
      assert String.trim(out) == "typed-ok"
    end

    test "reports the exit status with the captured output" do
      assert {:error, {:exit, 3, out}} =
               Windows.run_hidden("/bin/sh", ["-c", "echo boom; exit 3"])

      assert String.trim(out) == "boom"
    end

    test "does not hang forever on a stuck command" do
      assert {:error, {:timeout, _}} =
               Windows.run_hidden("/bin/sh", ["-c", "sleep 5"], timeout_ms: 150)
    end

    test "a missing executable is an error, not a crash" do
      assert {:error, {:spawn_failed, _}} = Windows.run_hidden("/nonexistent/pwsh", [])
    end
  end
end
