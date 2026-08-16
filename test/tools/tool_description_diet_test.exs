defmodule OptimalSystemAgent.Tools.ToolDescriptionDietTest do
  @moduledoc """
  What the diet cut, what it kept, and what must not creep back.

  ## Background

  Measured against `39544345`: the advertised tool array was 24 tools, 39,461
  bytes, ~9,866 tokens, re-sent on every request of every turn — and **62% of it
  was `description` prose, not schema**. `shell_execute`'s description alone was
  6,201 bytes, 25x mini-swe-agent's entire 243-byte tool surface, and
  mini-swe-agent beat OSA 6/6 to 4/6 in our own model-pinned head-to-head.

  Three competitors were read for the principle rather than the text:

    * **mini-swe-agent** — `BASH_TOOL` in `models/utils/actions_toolcall.py`:
      `"description": "Execute a bash command"`. 22 bytes.
    * **codex** — `shell_spec.rs:208`, the whole non-Windows description:
      *"Runs a shell command and returns its output. - Always set the `workdir`
      param … Do not use `cd` unless absolutely necessary."* ~150 bytes. Its
      `apply_patch` description is 118. Codex's 20.7 KB of instruction is in the
      **system prompt**, and the parameter contract is in the **parameter
      descriptions** — the tool description carries only the one thing the model
      reliably gets wrong.
    * **opencode** — `read.txt` (1,158 B) and `glob.txt` (517 B) are flat lists
      of *imperatives*, each an action taken differently: *"Call this tool in
      parallel when you know there are multiple files you want to read"*,
      *"Avoid tiny repeated slices"*, *"it is always better to speculatively
      perform multiple searches as a batch"*. No rationale anywhere.

  The extracted rule, applied to every sentence: **does this change what the
  model does?** If it explains, reassures, justifies, or restates the schema, it
  goes. The tests below pin the rules that survived that question, so a later
  edit cannot quietly drop a behavioural rule while trimming, or quietly re-add
  the prose that was removed.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.BashOutput.Prompt, as: BashOutput
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Prompt, as: FileRead
  alias OptimalSystemAgent.Tools.Builtins.FileTransform.Prompt, as: FileTransform
  alias OptimalSystemAgent.Tools.Builtins.Git.Prompt, as: Git
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Prompt, as: ShellExecute
  alias OptimalSystemAgent.Tools.Builtins.TaskWrite.Prompt, as: TaskWrite
  alias OptimalSystemAgent.Tools.Builtins.ToolSearch.Prompt, as: ToolSearch

  @diet_targets [ShellExecute, FileTransform, FileRead, TaskWrite, BashOutput, ToolSearch]
  @all_touched [Git | @diet_targets]

  # Combined description bytes of the six tools the diet targeted. Measured at
  # 14,916 B before and 8,303 B after. The ceiling is deliberately close to the
  # measured value: prose creeps back a sentence at a time, and a sentence at a
  # time is exactly what this is meant to catch.
  @diet_budget_bytes 9_000

  # ── The prefix must be byte-identical across turns ──────────────────────

  describe "prefix stability" do
    # Prompt caching depends on the assembled prefix being byte-identical for
    # every request in a session. A prior agent found `web_search` interpolating
    # the current month into its description, which silently broke the cached
    # prefix once a month. Descriptions must be compile/boot-time constant.
    test "every touched description renders byte-identically on repeat" do
      for mod <- @all_touched do
        first = mod.render([])
        assert first == mod.render([]), "#{inspect(mod)} is not stable across renders"
        assert first == mod.render(), "#{inspect(mod)} default arity disagrees"
      end
    end

    test "no description interpolates the wall clock" do
      now = DateTime.utc_now()
      year = Integer.to_string(now.year)

      month =
        Enum.at(
          ~w(January February March April May June July August September October
             November December),
          now.month - 1
        )

      for mod <- @all_touched do
        text = mod.render([])
        refute text =~ year, "#{inspect(mod)} interpolates the current year"
        refute text =~ month, "#{inspect(mod)} interpolates the current month"
      end
    end
  end

  # ── The rules that were kept, because each one changes behaviour ────────

  describe "shell_execute keeps its behavioural contracts" do
    defp shell, do: ShellExecute.render([])

    test "the permission-segmentation contract survives" do
      # The model has to know a compound line is scored as a whole, or it cannot
      # choose what to put in one. This is the rule, not the rationale.
      text = shell()
      assert text =~ "split at"
      assert text =~ "sends the WHOLE line to approval"
      assert text =~ "approved or refused AS A WHOLE"
    end

    test "heredocs are still declared unsuppressible" do
      text = shell()
      assert text =~ "never be saved as an always-allow rule"
      assert text =~ "prompt every time"
    end

    test "yield-not-kill background semantics survive" do
      text = shell()
      assert text =~ "YIELD, NOT a kill"
      assert text =~ "background_id"
      assert text =~ "do NOT re-run it"
      assert text =~ "run_in_background"
    end

    test "a daemonised service is still distinguished from a background job" do
      text = shell()
      assert text =~ "setsid nohup"
      assert text =~ "killed when the session"
    end

    test "the write-side routing and its one-clause reason survive" do
      text = shell()
      assert text =~ "sed -i"
      assert text =~ "allowed-write roots"
      assert text =~ "has not changed under you since"
    end

    test "computing an answer instead of reading the file survives" do
      text = shell()
      assert text =~ "ANSWER A QUESTION about a file"
      assert text =~ "Prefer one command that answers the question"
    end
  end

  describe "the other five keep theirs" do
    test "task_write keeps the exactly-one-in_progress state machine" do
      text = TaskWrite.render([])
      assert text =~ "EXACTLY ONE task `in_progress`"
      assert text =~ "BEFORE starting"
      assert text =~ "NEVER when"
    end

    test "file_read keeps the continuation stamp and the widen-don't-reslice rule" do
      text = FileRead.render([])
      assert text =~ "End of file"
      assert text =~ "offset=C to continue"
      assert text =~ "overlapping slices"
      assert text =~ "in parallel in one turn"
    end

    test "file_transform keeps `expect` as the guard that replaces the read" do
      text = FileTransform.render([])
      assert text =~ "Set `expect` on every mutating operation"
      assert text =~ "No prior"
      assert text =~ "assert_balanced"
    end

    test "bash_output keeps wait_ms as the one sanctioned wait" do
      text = BashOutput.render([])
      assert text =~ "DO NOT SPIN"
      assert text =~ "wait_ms"
      # And it must not resurrect the capitalised ban that contradicted the gate
      # directing the model to wait with this very tool.
      refute text =~ "DO NOT USE THIS TOOL TO WAIT"
      assert text =~ "one-shot"
    end

    test "tool_search keeps every query form" do
      text = ToolSearch.render([])

      for form <- ["select:", "server:", "notebook jupyter", "+slack send"] do
        assert text =~ form, "tool_search dropped the #{form} query form"
      end
    end
  end

  # ── The overlap the audit found, resolved in the text ───────────────────

  describe "the git / shell_execute overlap" do
    # 26 of 111 recorded `git` results were the model putting a shell string in
    # the subcommand slot — `'diff --stat' is not a git command`, `bad revision
    # 'log'` — because `shell_execute`'s own description names `git` and the
    # other 11,057 calls taught it shell syntax. The tool is not being removed,
    # so the boundary has to be stated where the confusion happens.
    test "git states the argument shape and defers the rest to shell_execute" do
      text = Git.render([])
      assert text =~ "ONE bare subcommand"
      assert text =~ "diff --stat"
      assert text =~ "shell_execute"
    end

    test "git keeps the destructive-command guardrail" do
      text = Git.render([])
      assert text =~ "reset --hard"
      assert text =~ "clean -f"
      assert text =~ "never `git add .`"
    end
  end

  # ── What was cut must stay cut ──────────────────────────────────────────

  describe "schema restatement stays out of the prose" do
    test "task_write does not re-enumerate the action enum" do
      # `action` is a JSON-Schema enum carrying all eleven names, and the
      # parameter descriptions already say which fields go with which action
      # ("for add", "for fail", "for add_dependency/remove_dependency"). The
      # prose listing them again was ~250 bytes of pure duplication.
      text = TaskWrite.render([])
      refute text =~ "add_dependency"
      refute text =~ "remove_dependency"
      refute text =~ "`next` for the next unblocked task"
    end

    test "file_transform does not re-enumerate the op names" do
      # The `op` parameter's own description is the enumeration:
      # "replace | replace_regex | delete_matching_lines | insert_after | ...".
      text = FileTransform.render([])
      refute text =~ "`insert_after` / `insert_before`"
      refute text =~ "`append` / `prepend`"
    end

    test "scaffolding headings are gone" do
      for mod <- @diet_targets do
        text = mod.render([])
        refute text =~ "## Operations", "#{inspect(mod)} regrew a heading"
        refute text =~ "## Worked examples", "#{inspect(mod)} regrew a heading"
        refute text =~ "## Rules", "#{inspect(mod)} regrew a heading"
        refute text =~ "When NOT to use", "#{inspect(mod)} regrew a heading"
      end
    end

    test "the fragmentation advice stays retired" do
      refute shell() =~ "Prefer several simple commands"
    end
  end

  describe "the diet holds" do
    test "the six targeted descriptions stay within budget" do
      total =
        @diet_targets
        |> Enum.map(&byte_size(&1.render([])))
        |> Enum.sum()

      assert total <= @diet_budget_bytes,
             "the six diet targets are #{total} B, over the #{@diet_budget_bytes} B ceiling — " <>
               "prose has crept back. Every sentence must change what the model does."
    end

    test "each targeted description is smaller than it was before the diet" do
      before = %{
        ShellExecute => 6201,
        FileTransform => 3293,
        FileRead => 1889,
        TaskWrite => 1655,
        BashOutput => 1145,
        ToolSearch => 733
      }

      for {mod, was} <- before do
        now = byte_size(mod.render([]))

        assert now < was,
               "#{inspect(mod)} is #{now} B, no smaller than the #{was} B it started at"
      end
    end
  end
end
