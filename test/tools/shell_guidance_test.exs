defmodule OptimalSystemAgent.Tools.ShellGuidanceTest do
  @moduledoc """
  What `shell_execute`'s description tells the model to do, and what it no
  longer tells it.

  ## Background

  Measured on `schemelike-metacircular-eval`, same model and task: OSA made 66
  write operations on the artefact against codex's 12, and ended at 201k context
  against codex's 94k. The single largest mechanism behind codex's number was
  not bigger edits — it was that codex answered *questions about a file* by
  running a program over it and reading back one line, twelve times, instead of
  pulling the file into context to look. OSA's tool description forbade every
  shell path to that idiom by name and additionally instructed fragmentation
  ("Prefer several simple commands over one compound line"), which is the exact
  opposite of what won.

  ## What was kept, and why it is not negotiable

  The write-side routing stays. `shell_execute` applies **no** `PathPolicy`: it
  is not checked against the allowed-write roots, does not consult the blocked
  and sensitive location rules, and does not touch the `FileState` staleness
  ledger. `file_edit`/`file_write` do all three. So `sed -i` and `>` are not a
  stylistic alternative to the file tools — they are the same operation with the
  sandbox and the stale-view check removed. That ban was narrowed to mutation
  only, never lifted.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Prompt, as: Shell

  defp shell, do: Shell.render()

  describe "the fragmentation instruction is gone" do
    test "it no longer advises several simple commands over one compound line" do
      refute shell() =~ "Prefer several simple commands"
    end

    test "the constraint that motivated it is still stated, as a fact" do
      # The real fact is worth keeping: it tells the model what to put in a
      # line. It just does not imply "use more lines".
      assert shell() =~ "approved or refused AS A WHOLE"
    end
  end

  describe "computing an answer about a file is now encouraged" do
    test "the description says to answer questions with a script rather than a read" do
      text = shell()
      assert text =~ "ANSWER A QUESTION about a file"
      assert text =~ "Prefer one command that answers the question"
    end

    test "the read-and-compute tools are named as permitted" do
      text = shell()

      for idiom <- ["awk", "python3 -c", "heredoc"] do
        assert text =~ idiom, "expected the description to permit #{idiom}"
      end
    end
  end

  describe "the write-side routing is kept, and says why" do
    test "shell mutation of files is still refused by name" do
      text = shell()
      assert text =~ "sed -i"
      assert text =~ "never"
    end

    test "the ban is justified by the sandbox property, not by taste" do
      # A ban the model is given no reason for is a ban it will route around
      # the moment it is inconvenient.
      text = shell()
      assert text =~ "allowed-write roots"
      assert text =~ "has not changed under you since"
    end

    test "reading and searching still route to the dedicated tools" do
      text = shell()
      assert text =~ "file_read not cat"
      assert text =~ "file_grep not grep"
    end
  end

  describe "the permission facts the model has to plan around are stated" do
    test "heredocs and command substitution are declared unsuppressible" do
      # This is a real property of `Permissions.suggested_prefix/1` and it is
      # deliberately unchanged: a prefix rule cannot describe a heredoc body, so
      # offering one would be dishonest about what the operator approved. The
      # model is told, so it can choose a single self-contained script instead
      # of paying the prompt several times.
      text = shell()
      assert text =~ "never be saved as an always-allow rule"
      assert text =~ "prompt every time"
    end
  end
end
