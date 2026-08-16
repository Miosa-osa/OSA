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

  ## Why these assertions moved off the description

  Every rule below is still delivered, but the *placement* changed: routing and
  the answer-with-a-program habit are policy and are now stated once in
  `SYSTEM.md` §5 instead of restated in five tool descriptions, and the
  permission-segmentation contract now sits on the `command` parameter, next to
  the value it constrains. So the subject under test is **what the model
  receives**, not which string it arrives in — and each rule additionally
  asserts it is NOT restated on the other surface, because paying for the same
  sentence twice is the thing the relocation removed.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Prompt, as: Shell
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Tool, as: ShellTool

  defp shell, do: Shell.render()
  defp params, do: Jason.encode!(ShellTool.parameters())
  defp system, do: File.read!("priv/prompts/SYSTEM.md")
  defp system_lean, do: File.read!("priv/prompts/SYSTEM_LEAN.md")

  describe "the fragmentation instruction is gone" do
    test "it no longer advises several simple commands over one compound line" do
      refute shell() =~ "Prefer several simple commands"
    end

    test "the constraint that motivated it is still stated, as a fact" do
      # The real fact is worth keeping: it tells the model what to put in a
      # line. It just does not imply "use more lines". It now lives on the
      # `command` parameter, which is the value it constrains.
      assert params() =~ "approved or refused AS A WHOLE"
      refute shell() =~ "approved or refused AS A WHOLE"
    end
  end

  describe "computing an answer about a file is now encouraged" do
    test "the system prompt makes the program-based answer a named default route" do
      # Stated once, as policy, with the four questions that have a program
      # answer named explicitly — not restated per tool.
      text = system()
      assert text =~ "Answer With a Program, Not With a Read"
      assert text =~ "Prefer one command that answers the question"

      for question <- ["Is it well-formed?", "Did my edit land?", "How many X"] do
        assert text =~ question, "expected the routing block to name #{question}"
      end
    end

    test "the lean system prompt carries the same route" do
      assert system_lean() =~ "Answer with a program, not with a read"
    end

    test "the read-and-compute tools are named as permitted" do
      text = system()

      for idiom <- ["awk", "python3 -c", "heredoc"] do
        assert text =~ idiom, "expected the routing block to permit #{idiom}"
      end
    end

    test "shell_execute still advertises itself for that job without restating the rule" do
      assert shell() =~ "compute answers about the tree"
      refute shell() =~ "ANSWER A QUESTION about a file"
    end
  end

  describe "the write-side routing is kept, and says why" do
    test "shell mutation of files is still refused by name, on both system prompts" do
      for text <- [system(), system_lean()] do
        assert text =~ "sed -i"
        assert text =~ "never"
      end
    end

    test "the ban is justified by the sandbox property, not by taste" do
      # A ban the model is given no reason for is a ban it will route around
      # the moment it is inconvenient.
      assert system() =~ "allowed-write roots"
      assert system() =~ "changed under you"
      assert system_lean() =~ "allowed-write roots"
    end

    test "reading and searching still route to the dedicated tools" do
      text = system_lean()
      assert text =~ "`file_read` not `cat`"
      assert text =~ "`file_grep` not shell grep"
      assert system() =~ "not shell_execute with cat"
      assert system() =~ "not shell_execute with grep/rg"
    end

    test "the routing table is not restated in the shell_execute description" do
      # Five restatements of one policy is what this relocation removed.
      refute shell() =~ "sed -i"
      refute shell() =~ "file_read not cat"
    end
  end

  describe "the permission facts the model has to plan around are stated" do
    test "heredocs and command substitution are declared unsuppressible" do
      # This is a real property of `Permissions.suggested_prefix/1` and it is
      # deliberately unchanged: a prefix rule cannot describe a heredoc body, so
      # offering one would be dishonest about what the operator approved. The
      # model is told, so it can choose a single self-contained script instead
      # of paying the prompt several times.
      text = params()
      assert text =~ "never be saved as an always-allow rule"
      assert text =~ "prompt every time"
    end
  end
end
