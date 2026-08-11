defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.ReplaceAllGuardTest do
  @moduledoc """
  End-to-end coverage of the `replace_all`-requires-an-exact-match guard,
  through `FileEdit.Handler` and onto DISK.

  The defect this pins down is not a wrong answer in context: the old code
  applied `global: true` to whatever candidate the winning *approximate*
  strategy produced, so `replace_all` rewrote regions of the user's source that
  never contained `old_string`, wrote the result to disk, and reported success.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEdit
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    FileState.reset()
    DriftGuard.reset()
    sid = "replace-all-guard-#{System.unique_integer([:positive])}"
    ctx = %UseContext{session_id: sid, permission_tier: :full}

    path =
      Path.join(System.tmp_dir!(), "osa_replace_all_#{System.unique_integer([:positive])}.txt")

    on_exit(fn -> File.rm(path) end)
    {:ok, ctx: ctx, path: path}
  end

  defp edit(path, old, new, ctx, replace_all) do
    FileEdit.execute(
      %{
        "path" => path,
        "old_string" => old,
        "new_string" => new,
        "replace_all" => replace_all
      },
      ctx
    )
  end

  # `old` differs from disk only by whitespace RUNS, so no exact / line-ending /
  # trim stage can match it and the cascade reaches :whitespace_normalized.
  # That strategy's candidate — "total = count + 1" — occurs twice: once as the
  # real statement, and once embedded in a COMMENT that is not code at all.
  @source """
  # note: total = count + 1 is the invariant
  total = count + 1
  """
  @drifted_old "total  =  count + 1"

  test "an approximate replace_all leaves the file on disk untouched", %{ctx: ctx, path: path} do
    File.write!(path, @source)
    assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

    assert {:error, _msg} = edit(path, @drifted_old, "total = tally()", ctx, true)

    # The whole point: nothing was written. Previously the comment line came
    # back as "# note: total = tally() is the invariant".
    assert File.read!(path) == @source
  end

  test "the refusal names what was wrong AND the next step", %{ctx: ctx, path: path} do
    File.write!(path, @source)
    assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

    assert {:error, msg} = edit(path, @drifted_old, "total = tally()", ctx, true)

    # What was wrong.
    assert msg =~ "Refusing replace_all"
    assert msg =~ "does not appear in the file verbatim"
    assert msg =~ "matched approximately"
    assert msg =~ "whitespace_normalized"
    assert msg =~ "never contained old_string"

    # What to do next — both offered remedies, named explicitly.
    assert msg =~ "Next step:"
    assert msg =~ "re-read"
    assert msg =~ "longer old_string"
    assert msg =~ "edit each site individually"
  end

  test "exact replace_all still rewrites every occurrence (the legitimate case)",
       %{ctx: ctx, path: path} do
    File.write!(path, "a = count\nb = count\nc = count\n")
    assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

    assert {:ok, result} = edit(path, "count", "total", ctx, true) |> normalize()
    assert result =~ "3 occurrences"
    assert File.read!(path) == "a = total\nb = total\nc = total\n"
  end

  test "a non-replace_all fuzzy edit is unaffected by the guard", %{ctx: ctx, path: path} do
    # Single drifted site, replace_all false: the cascade still applies it.
    File.write!(path, "value   =   compute()\n")
    assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

    assert {:ok, _} =
             edit(path, "value = compute()", "value = cached()", ctx, false) |> normalize()

    assert File.read!(path) == "value = cached()\n"
  end

  # Handler returns {:ok, result} or {:ok, result, meta} depending on diff size.
  defp normalize({:ok, result, _meta}), do: {:ok, result}
  defp normalize(other), do: other
end
