defmodule OptimalSystemAgent.Tools.Builtins.FileTransform.Prompt do
  @moduledoc """
  Dynamic prompt for `file_transform`.

  The text below is doing a specific job and its shape is deliberate. Three
  things were measured about how winning harnesses instruct edits, and all
  three are applied here:

    * **Worked examples, as copyable text.** mini-swe-agent's only real
      instruction is a section called "Useful command examples" containing
      runnable snippets, and it has the largest median tool argument in the
      field. A parameter description reading "Content to write" produces small
      timid calls; a worked example produces the idiom.
    * **The rule of choice stated at the tool, not only in SYSTEM.md.** opencode
      teaches batching in `read.txt`, not in its system prompt, because the
      instruction has to be one indirection closer to the affordance than the
      alternative it competes with.
    * **The recovery rule, measured.** Across the benchmark corpus this tool is
      chosen for 6-7.5% of edit operations on long runs and fails at 10.3% —
      the highest of any edit tool — and two of three observed failures were
      `expect` count mismatches. The per-run traces show a burst of calls
      followed by permanent reversion to `file_edit` after the first friction.
      So the description now says what to do on a miss, and `expect` is
      documented as optional-unless-known rather than mandatory.
    * **The probe idiom named explicitly.** Codex ran a self-authored
      paren-balance checker twelve times and read back one word. That behaviour
      never emerges from a tool description that only talks about editing, so
      `count` and `assert_balanced` are shown here doing exactly that job.
  """

  @doc "Render the file_transform tool prompt."
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    edit_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileEdit.Constants, :tool_name, "file_edit")

    """
    Changes a file by describing the change, without quoting the file's contents.
    Applies an ordered list of operations to ONE existing file and writes the
    result atomically: if any operation misses its expectation, NOTHING is
    written and you are told which one and why.

    Prefer this over `#{edit_name}` whenever you can name what to change by an
    anchor — a pattern, a matching line, the end of the file — rather than by
    exact bytes. Use `#{edit_name}` only when the change needs the exact
    surrounding bytes to be unambiguous, and `file_write` for a full rewrite.

    A missed expectation is a MISS, not a reason to give up on this tool: nothing
    was written, the error names the count actually found, and the fix is the
    same call with that count. Falling back to `#{edit_name}` there costs you the
    whole file for a one-word correction.

    Delete a defective definition and check the file still balances, in one call:

        {"path": "eval.scm",
         "operations": [
           {"op": "delete_matching_lines", "pattern": "^\\\\(define \\\\(caddddr", "expect": 1},
           {"op": "assert_balanced"}
         ]}

    The file must already exist — use `file_write` to create one. No prior
    `#{read_name}` is required.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
