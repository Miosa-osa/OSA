defmodule OptimalSystemAgent.Scripts.InstallModesTest do
  use ExUnit.Case, async: true

  @tag timeout: 120_000
  test "prebuilt installer and updater preserve full and headless contracts" do
    python = System.find_executable("python3") || flunk("python3 is required for installer tests")
    script = Path.expand("../shell/install_modes_test.py", __DIR__)
    {output, status} = System.cmd(python, [script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
