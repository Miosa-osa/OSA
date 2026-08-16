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
    Executes a shell command and returns its output. Use it for system commands \
    (git, mix, npm, cargo, docker, make) and to compute answers about the tree. \
    Always set `cwd`; never `cd`. Prefer absolute literal paths, quoted if they \
    contain spaces.

    Routing. To LOOK AT a file or find one: file_read not cat/head/tail, \
    file_grep not grep/rg, file_glob not find, dir_list not ls. To CHANGE a \
    file: file_edit / file_transform / multi_file_edit / file_write, never \
    `sed -i`, `>` or `>>` — only the file tools enforce the allowed-write roots \
    and check the file has not changed under you since you read it.

    But DO reach for the shell to ANSWER A QUESTION about a file rather than \
    reading the file to answer it yourself. Pipelines, `awk`, `python3 -c`, \
    `&&`-chains and heredocs are all fair game here. Prefer one command that \
    answers the question over three that circle it.

    Batch UNRELATED commands as separate calls IN ONE TURN. Do not chain them \
    with `;` — that merges their exit codes into one approval. The bar is that \
    neither reads what the other writes, so a build and the test run that \
    consumes it stay in separate turns.

    Permission check: the line is split at `|`, `&&`, `||`, `;`, `&` (not inside \
    quotes or `$(...)`) and each segment's first word classified. ONE risky \
    segment — rm, sudo, chmod, chown, kill, mount, systemctl, nc, shutdown, \
    piping into a shell, redirecting into system directories, `git reset --hard`, \
    `git clean -f`, force-push, or a file-mutating command reaching outside the \
    working directory — sends the WHOLE line to approval, and it is approved or \
    refused AS A WHOLE, so keep an unrelated risky step out of a line you want \
    waved through. A heredoc (`<<`) or command substitution (`$(`, backticks) can \
    never be saved as an always-allow rule and will prompt every time; favour one \
    self-contained `-c` script over several heredocs.

    Long-running commands: the tool waits a bounded window (2 min default). That \
    is a YIELD, NOT a kill — on elapse the command MOVES TO THE BACKGROUND still \
    running and you get a `background_id`, so do NOT re-run it. Pass \
    `run_in_background: true` up front for long jobs whose result you will come \
    back for. Never poll one: if you need the result take it in a single \
    `bash_output` call with `wait_ms`, and if you do not, leave it alone.

    Servers are a THIRD case: `run_in_background` is killed when the session \
    ends. If the task asks for a service still listening after you finish, \
    daemonise it out of the session yourself — \
    `setsid nohup <cmd> </dev/null >/tmp/<name>.log 2>&1 &` — then VERIFY it \
    independently (`curl`, `ss -ltnp`) and say you left it running.

    Discovery scans (du, find, ls -R): bound the first pass (`-maxdepth`, \
    `-d 1`), never re-scan covered ground, stop once the question is answered. On \
    a non-zero exit or a yield, CHANGE the command — narrow it, exclude the \
    failing path, or use a cheaper tool; never retry a near-identical variant. \
    "Operation not permitted" on system paths is EXPECTED — prune and move on.
    """
  end
end
