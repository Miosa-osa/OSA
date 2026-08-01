defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.Prompt do
  @moduledoc """
  Dynamic prompt for `shell_execute`.

  Mirrors the pattern from `FileRead.Prompt` — tool name references are
  resolved lazily so renames propagate automatically.
  """

  @doc """
  Render the shell_execute tool prompt.

  `opts` is reserved for future signal-aware customization.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Executes a shell command and returns its output.

    IMPORTANT: Avoid using this tool to run cat, head, tail, sed, awk, or echo commands. \
    Instead use the dedicated tools:
    - File search: Use file_glob (NOT find or ls)
    - Content search: Use file_grep (NOT grep or rg)
    - Read files: Use file_read (NOT cat/head/tail)
    - Edit files: Use file_edit (NOT sed/awk)
    - Write files: Use file_write (NOT echo/cat)

    Reserve shell_execute for system commands: git, mix, npm, cargo, docker, make, pip, etc.
    Always quote file paths with spaces. Try to use absolute paths.

    Working directory:
    - ALWAYS set the `cwd` param. Do not use `cd` unless absolutely necessary.
    - `cwd` defaults to the session's current working directory.

    How the permission check reads your command:
    - The command string is split into segments at the shell control operators `|`, `&&`, \
    `||`, `;` and `&`. Operators inside quotes, `$(...)`, `${...}` or backticks do not split.
    - Each segment's first word is classified on its own, and the command runs unprompted \
    only when EVERY segment is approvable. One risky segment (rm, sudo, chmod, chown, kill, \
    mount, systemctl, nc, shutdown, …) sends the WHOLE line to the approval prompt.
    - Some rules match the whole command string rather than one segment: piping into a shell \
    (`curl … | sh`), redirecting into system directories (/etc, /usr/bin, …), and \
    `git reset --hard` / `git clean -f` / force-push all require approval. A small set of \
    unrecoverable operations (wiping `/` or `$HOME`, mkfs, dd to a block device, fork bombs) \
    is denied outright and cannot be approved.
    - A file-mutating command (rm, cp, mv, mkdir, touch, chmod, chown, ln, tee, rsync, install) \
    that touches a path outside the working directory also requires approval. Path arguments \
    that are globs or contain `$VAR`, `$(...)` or backticks cannot be resolved statically, so \
    the checker cannot see what they touch — prefer literal paths.
    - Prefer several simple, individually approvable commands over one long compound line: a \
    compound line is approved or refused as a whole, and approving yields a reusable scoped \
    rule (e.g. `git checkout *`, `npm run dev *`) only for the segments it could parse.
    - A trailing `&` is stripped and the command runs in the foreground. A command ending in a \
    dangling `&&`, `||`, `|` or `\\` is rejected — send a complete command.

    Long-running commands (IMPORTANT):
    - The tool waits a bounded window (2 minutes by default, configurable) for a foreground \
    command. This is a YIELD window, NOT a kill deadline.
    - If the command is still running when the window elapses it is MOVED TO THE BACKGROUND, \
    not killed. The result says "Still running … moved to the background (NOT killed)" and \
    carries a `background_id`. The command is STILL RUNNING and its work is not lost.
    - When that happens do NOT re-run the command.
    - If you already expect the command to be long (builds, full test suites, servers), pass \
    `run_in_background: true` up front to get a `background_id` immediately.

    Once a command is in the background you WILL be notified when it finishes — automatically, \
    with its exit code, its output tail and a path to its full output file. The notification \
    re-enters your context on its own. Therefore:
    - Do NOT poll. Do NOT call bash_output "just to check". Do NOT run `sleep`. Do NOT re-run \
    `ls`/`wc`/`test -f` to see whether the artifact appeared yet. Waiting burns turns and \
    wall-clock on work the harness already reports.
    - Instead, move on: do unrelated work that does not depend on the result, or if there is \
    nothing else to do, stop and let the notification wake you.
    - Only call bash_output when you need the output of a command you were ALREADY told finished, \
    or to stop one early with `kill: true`.

    Discovery scans (du, find, ls -R): bound the FIRST pass cheaply (`-maxdepth`, `-d 1`), never \
    re-scan ground an earlier command covered, and stop once the question is answered. On a \
    non-zero exit or a yield CHANGE the command — narrow the scope, exclude the failing path, or \
    use a cheaper tool; do not retry a near-identical variant. "Operation not permitted" on \
    system paths (`.Trash`, `Library`, `/System`) is EXPECTED — prune and move on.
    """
  end
end
