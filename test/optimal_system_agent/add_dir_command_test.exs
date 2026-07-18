defmodule OptimalSystemAgent.AddDirCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Permissions

  test "/add-dir validates and records an existing directory" do
    tmp = Path.join(System.tmp_dir!(), "osa_adddir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    out = capture_io(fn -> Commands.cmd_add_dir(tmp, "s1") end)

    assert out =~ "Added working directory"
    assert Path.expand(tmp) in Permissions.additional_directories()
  end

  test "/add-dir rejects a missing path" do
    out = capture_io(fn -> Commands.cmd_add_dir("/definitely/not/here_osa_123", "s1") end)
    assert out =~ "does not exist"
  end

  test "/add-dir with no argument prints usage" do
    out = capture_io(fn -> Commands.cmd_add_dir("", "s1") end)
    assert out =~ "Usage: /add-dir"
  end
end
