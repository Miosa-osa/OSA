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

    Use this instead of `#{edit_name}` whenever you can name what to change by an
    anchor rather than by exact bytes — a pattern, a line that matches, the end of
    the file. `#{edit_name}` requires you to reproduce the old text exactly, which
    means you must hold the file in context; this tool does not, so the cost of a
    change does not grow with the size of the file. On a large file that is the
    difference between a 200-byte call and a 3,000-byte one.

    It applies an ordered list of operations to ONE existing file, in memory, and
    writes the result atomically. If any operation does not match what it expects,
    NOTHING is written and you are told which one and why. A partial or silently
    wrong edit is not a possible outcome.

    ## Operations

    - `replace` — `find` (literal text), `to`
    - `replace_regex` — `pattern`, `to` (use `\\\\1` for capture groups)
    - `delete_matching_lines` — `pattern`
    - `insert_after` / `insert_before` — `pattern`, `text`
    - `append` / `prepend` — `text`
    - `count` — `pattern`; reports how many matches, changes nothing
    - `assert_balanced` — `open`, `close` (default `(` and `)`); aborts if unbalanced

    Every mutating operation takes an optional `expect` (an integer). Omitted, it
    means "at least one" — matching zero times is always an error. Given, the match
    count must equal it exactly. Use it: it is what makes an unread file safe to
    edit, because a file that changed underneath you no longer matches the count.

    ## Answer questions about a file by running an operation over it, not by reading it

    `count` and `assert_balanced` change nothing and return one line. Checking
    whether your parentheses balance costs the same whether the file is 50 lines or
    5,000, and it does not put the file in your context.

        {"path": "eval.scm", "operations": [{"op": "assert_balanced"}]}
        -> eval.scm — 1 operation(s), no change to the file
             1. assert_balanced — balance: 0 (() balanced)

    Set `dry_run: true` to see what a whole operation list would do without writing.

    ## Worked examples

    Delete a defective definition and check the file still balances, in one call:

        {"path": "eval.scm",
         "operations": [
           {"op": "delete_matching_lines", "pattern": "^\\\\(define \\\\(caddddr", "expect": 1},
           {"op": "assert_balanced"}
         ]}

    Rename every call site, and state how many there should be:

        {"path": "src/server.py",
         "operations": [
           {"op": "replace", "find": "get_user_by_id", "to": "fetch_user", "expect": 7}
         ]}

    Add an import at the top and a handler after a marker:

        {"path": "app.ex",
         "operations": [
           {"op": "prepend", "text": "import Config"},
           {"op": "insert_after", "pattern": "^  # handlers", "text": "  def ping, do: :pong",
            "expect": 1}
         ]}

    ## Rules

    - The file must already exist. Use `file_write` to create one.
    - No prior `#{read_name}` is required. The `expect` counts are the guard.
    - Do NOT `#{read_name}` afterwards to check the result. The observation already
      tells you how many lines and bytes changed, and reports any post-edit
      validation failure.
    - Reach for `#{edit_name}` when the change genuinely needs exact surrounding
      bytes to be unambiguous, and for a full rewrite use `file_write`.
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
