defmodule OptimalSystemAgent.Security.PostEditFormatterEvalTest do
  @moduledoc """
  `Verify.PostEdit` runs on EVERY file_edit / multi_file_edit / file_write, and
  it reads formatting options out of the nearest `.formatter.exs` walking up to
  40 parent directories.

  `.formatter.exs` is arbitrary Elixir source belonging to whatever repository
  happens to be on disk. Evaluating it meant that editing one file in any cloned
  repo executed that repo's code inside the agent's BEAM, with the agent's full
  filesystem and network access.

  These tests hold the line: the options must be READ, never RUN.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Verify.PostEdit

  @moduletag :security

  setup do
    dir = Path.join(System.tmp_dir!(), "pe_eval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp noop_exec, do: fn _program, _args, _cwd -> {"", 0} end

  test "a .formatter.exs is never executed while formatting a file next to it", ctx do
    canary = Path.join(ctx.dir, "PWNED")

    # A perfectly ordinary-looking .formatter.exs with a payload in it. If this
    # file is evaluated, the canary appears. This is exactly what a malicious
    # (or merely unlucky) repository would ship.
    File.write!(Path.join(ctx.dir, ".formatter.exs"), """
    File.write!(#{inspect(canary)}, "arbitrary code executed")
    [line_length: 120, inputs: ["**/*.ex"]]
    """)

    # Deliberately unformatted so the format path definitely runs.
    target = Path.join(ctx.dir, "sample.ex")
    File.write!(target, "defmodule A do\n  def   b,   do:    1\nend\n")

    PostEdit.analyze(target, noop_exec())

    refute File.exists?(canary),
           "editing a file executed the repository's .formatter.exs"
  end

  test "a .formatter.exs in a PARENT directory is not executed either", ctx do
    canary = Path.join(ctx.dir, "PWNED_PARENT")

    File.write!(Path.join(ctx.dir, ".formatter.exs"), """
    File.write!(#{inspect(canary)}, "arbitrary code executed")
    [line_length: 120]
    """)

    nested = Path.join([ctx.dir, "lib", "deep", "deeper"])
    File.mkdir_p!(nested)
    target = Path.join(nested, "sample.ex")
    File.write!(target, "defmodule A do\n  def   b,   do:    1\nend\n")

    PostEdit.analyze(target, noop_exec())

    refute File.exists?(canary),
           "editing a nested file executed an ancestor's .formatter.exs"
  end

  test "literal formatter options are still honoured", ctx do
    # :line_length is read straight off the AST. With a very small line length
    # the formatter must break this call across lines; with the default 98 it
    # would fit on one. This proves the options are being READ, not ignored.
    File.write!(Path.join(ctx.dir, ".formatter.exs"), """
    [line_length: 20, inputs: ["**/*.ex"]]
    """)

    target = Path.join(ctx.dir, "sample.ex")
    File.write!(target, "aaaaaaaa = some_function(bbbbbbbb, cccccccc, dddddddd)\n")

    PostEdit.analyze(target, noop_exec())

    assert File.read!(target) =~ "\n", "file should have been formatted"

    assert length(String.split(File.read!(target), "\n")) > 2,
           "line_length: 20 from .formatter.exs was not applied"
  end

  test "a computed (non-literal) option is dropped rather than evaluated", ctx do
    File.write!(Path.join(ctx.dir, ".formatter.exs"), """
    [line_length: 20, inputs: Path.wildcard("**/*.ex")]
    """)

    target = Path.join(ctx.dir, "sample.ex")
    File.write!(target, "aaaaaaaa = some_function(bbbbbbbb, cccccccc, dddddddd)\n")

    # Must not raise, and the literal option next to the computed one survives.
    PostEdit.analyze(target, noop_exec())

    assert length(String.split(File.read!(target), "\n")) > 2
  end

  test "a syntactically broken .formatter.exs degrades to defaults, not a crash", ctx do
    File.write!(Path.join(ctx.dir, ".formatter.exs"), "[line_length: ,,,")

    target = Path.join(ctx.dir, "sample.ex")
    File.write!(target, "defmodule A do\n  def   b,   do:    1\nend\n")

    assert PostEdit.analyze(target, noop_exec()) == ""
  end
end
