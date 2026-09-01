defmodule OptimalSystemAgent.Verify.PostEditFormatGateTest do
  @moduledoc """
  Diagnostics always run; the in-place REFORMAT is gated behind
  `post_edit_format_enabled` (default OFF in prod). async: false because it
  toggles the app-env default, and ExUnit runs sync tests in isolation so this
  never races the formatter eval suite (which relies on formatting being on).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Verify.PostEdit

  @unformatted "defmodule Sample do\n  def   x,   do:    1\nend\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "post_edit_gate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "sample.ex")
    File.write!(path, @unformatted)
    %{path: path}
  end

  defp noop_exec, do: fn _cmd, _args, _dir -> {"", 0} end

  test "format disabled: file is left untouched but still validated", %{path: path} do
    prev = Application.get_env(:optimal_system_agent, :post_edit_format)
    Application.put_env(:optimal_system_agent, :post_edit_format, false)
    on_exit(fn -> Application.put_env(:optimal_system_agent, :post_edit_format, prev) end)

    refute PostEdit.format_enabled?()
    # Valid source → no diagnostics, and crucially the bytes are NOT rewritten.
    assert PostEdit.analyze(path, noop_exec()) == ""
    assert File.read!(path) == @unformatted
  end

  test "format enabled: file is reformatted in place", %{path: path} do
    prev = Application.get_env(:optimal_system_agent, :post_edit_format)
    Application.put_env(:optimal_system_agent, :post_edit_format, true)
    on_exit(fn -> Application.put_env(:optimal_system_agent, :post_edit_format, prev) end)

    assert PostEdit.format_enabled?()
    assert PostEdit.analyze(path, noop_exec()) == ""
    reformatted = File.read!(path)
    assert reformatted != @unformatted
    assert reformatted =~ "def x, do: 1"
  end
end
