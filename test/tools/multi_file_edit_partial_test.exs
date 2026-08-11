defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEditPartialTest do
  @moduledoc """
  `multi_file_edit` is all-or-nothing by design — a write that fails partway
  must never leave the repo half-edited. But that guarantee was being spent on
  the wrong thing: a hunk that was ALREADY APPLIED failed validation, and one
  such hunk failed the entire batch.

  The consequence is a trap, not just an annoyance. If a batch partially lands
  (or the model re-issues a batch it already ran), every retry now contains at
  least one already-applied hunk — so every retry fails, forever. The batch
  becomes permanently unusable and the only escape is editing files one at a
  time.

  Single-file `file_edit` has treated this as idempotent success for a while
  (`already_applied_or_not_found/3`); `multi_file_edit` has its own apply logic
  and never inherited it. These tests pin the inherited behaviour, including
  the narrowness that keeps failed DELETIONS a hard error.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Handler
  alias OptimalSystemAgent.Tools.UseContext

  # "test" is FileState's read-before-edit exempt sentinel — these tests are
  # about batch outcome reporting, not read-before-edit.
  defp ctx, do: %UseContext{session_id: "test"}

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_mfe_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp edit(path, old, new),
    do: %{"path" => path, "old_string" => old, "new_string" => new}

  describe "an already-applied hunk no longer kills the batch" do
    test "the remaining hunks still apply", %{dir: dir} do
      # `a` is already in the requested state; `b` is not.
      a = write(dir, "a.ex", "value = :new_a\n")
      b = write(dir, "b.ex", "value = :old_b\n")

      assert {:ok, msg, meta} =
               Handler.execute(
                 %{
                   "edits" => [
                     edit(a, "value = :old_a", "value = :new_a"),
                     edit(b, "value = :old_b", "value = :new_b")
                   ]
                 },
                 ctx()
               )

      assert File.read!(b) == "value = :new_b\n", "the applicable hunk must still land"
      assert File.read!(a) == "value = :new_a\n", "the already-applied file is untouched"

      # Per-hunk reporting: the skipped hunk is named, not silently dropped.
      assert meta.count == 1
      assert meta.already_applied == [a]
      assert msg =~ "already applied"
    end

    test "a batch where EVERY hunk is already applied is a success, not a failure",
         %{dir: dir} do
      # This is the retry-after-partial-success case exactly.
      a = write(dir, "a.ex", "value = :new_a\n")
      b = write(dir, "b.ex", "value = :new_b\n")

      assert {:ok, msg, meta} =
               Handler.execute(
                 %{
                   "edits" => [
                     edit(a, "value = :old_a", "value = :new_a"),
                     edit(b, "value = :old_b", "value = :new_b")
                   ]
                 },
                 ctx()
               )

      assert meta.count == 0
      assert length(meta.already_applied) == 2
      assert msg =~ "already applied"
      assert File.read!(a) == "value = :new_a\n"
      assert File.read!(b) == "value = :new_b\n"
    end
  end

  describe "the idempotency is narrow — it cannot swallow real failures" do
    test "a failed DELETION is still a hard error", %{dir: dir} do
      # new_string == "" is trivially 'present' in every file. Treating that as
      # applied would make every genuinely failed deletion look like success.
      f = write(dir, "d.ex", "keep this\n")

      assert {:error, msg} =
               Handler.execute(
                 %{"edits" => [edit(f, "delete this line", "")]},
                 ctx()
               )

      assert msg =~ "old_string not found"
      assert File.read!(f) == "keep this\n"
    end

    test "a hunk whose new_string is absent is still a hard error", %{dir: dir} do
      f = write(dir, "e.ex", "totally unrelated content\n")

      assert {:error, msg} =
               Handler.execute(
                 %{"edits" => [edit(f, "value = :old", "value = :new")]},
                 ctx()
               )

      assert msg =~ "old_string not found"
    end

    test "a genuine error still fails the whole batch and writes nothing", %{dir: dir} do
      ok_file = write(dir, "ok.ex", "value = :old_ok\n")
      bad_file = write(dir, "bad.ex", "nothing matches here\n")

      assert {:error, msg} =
               Handler.execute(
                 %{
                   "edits" => [
                     edit(ok_file, "value = :old_ok", "value = :new_ok"),
                     edit(bad_file, "value = :missing", "value = :whatever")
                   ]
                 },
                 ctx()
               )

      assert msg =~ "no files were modified"

      assert File.read!(ok_file) == "value = :old_ok\n",
             "atomicity must survive: a real error rolls the batch back"
    end
  end

  describe "per-hunk outcome reporting" do
    test "a failed batch names every hunk's outcome, not just the failures",
         %{dir: dir} do
      applied = write(dir, "applied.ex", "value = :new_a\n")
      fine = write(dir, "fine.ex", "value = :old_b\n")
      broken = write(dir, "broken.ex", "unrelated\n")

      assert {:error, msg} =
               Handler.execute(
                 %{
                   "edits" => [
                     edit(applied, "value = :old_a", "value = :new_a"),
                     edit(fine, "value = :old_b", "value = :new_b"),
                     edit(broken, "value = :nope", "value = :yep")
                   ]
                 },
                 ctx()
               )

      # The model needs all three verdicts to know what to reissue.
      assert msg =~ "#{applied}: already applied"
      assert msg =~ "#{fine}: would apply cleanly"
      assert msg =~ "#{broken}: old_string not found"
    end
  end
end
