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

    Use it for system commands (git, mix, npm, cargo, docker, make) and for \
    computing answers about the tree. ALWAYS set `cwd` rather than using `cd`. \
    Quote paths with spaces; prefer absolute, literal paths.

    Routing. To LOOK AT a file or find one, use the dedicated tools — file_read \
    not cat/head/tail, file_grep not grep/rg, file_glob not find, dir_list not \
    ls: they page, clamp and number lines, and they tell you where the file \
    ends. To CHANGE a file, use file_edit / multi_file_edit / file_write, never \
    `sed -i`, `>` or `>>`. That one is not a style preference: the file tools are \
    the only write path that enforces the allowed-write roots, refuses sensitive \
    and blocked locations, and checks the file has not changed under you since \
    you read it. A shell redirect has none of that and can silently clobber work.

    But DO reach for the shell to ANSWER A QUESTION about a file rather than \
    reading the file to answer it yourself. A one-line script that returns \
    `balance: 0`, a count, a diff, a list of offending line numbers, or `OK` \
    costs a few hundred bytes; pulling the file into context to work it out \
    yourself costs the whole file, every time you check. Pipelines, `awk`, \
    `python3 -c`, `&&`-chains and heredocs are all fair game for this — they read \
    and compute, they do not mutate, so none of the write concerns above apply. \
    Prefer one command that answers the question over three that circle it.

    Compression and batching are different moves and you want both. Compression \
    is one command that answers one question instead of three that circle it — \
    that is the paragraph above. Batching is several UNRELATED commands going \
    out as several `shell_execute` calls IN THE SAME TURN: the status and the \
    diff, the two test files, the build and the lint. Do not spend a turn each \
    on those. And do not reach for `;` to fake it — chaining unrelated commands \
    into one line merges their exit codes and sends the whole line to one \
    approval decision, which is worse on both counts. Separate calls, one turn.

    What batching buys is round trips, not concurrency, so the bar for putting \
    two commands in one turn is that neither reads what the other writes. A \
    build and the test run that consumes it stay in separate turns; `git status` \
    and `git diff`, or two independent test files, do not. When in doubt about \
    ordering, batch the reads and keep the writes on their own.

    Permission check: the line is split at `|`, `&&`, `||`, `;`, `&` (not inside \
    quotes or `$(...)`) and each segment's first word is classified — one risky \
    segment (rm, sudo, chmod, chown, kill, mount, systemctl, nc, shutdown) sends \
    the WHOLE line to approval, as do piping into a shell, redirecting into system \
    directories, `git reset --hard`, `git clean -f`, force-push, and file-mutating \
    commands touching paths outside the working directory. Wiping `/` or `$HOME`, \
    mkfs, dd to a block device and fork bombs are denied outright. Globs and `$VAR` \
    in path arguments cannot be resolved statically. A dangling trailing `&&`, \
    `||`, `|` or `\\` is rejected.

    Two consequences of that check to plan around — neither is a reason to \
    fragment work that belongs in one command. A compound line is approved or \
    refused AS A WHOLE, so keep an unrelated risky step out of a line you want \
    waved through; that is about what you put in the line, not how many lines you \
    use. And a command containing a heredoc (`<<`) or command substitution \
    (`$(`, backticks) can never be saved as an always-allow rule, because a \
    prefix cannot describe what its body does — such commands prompt every time, \
    so favour a single self-contained `-c` script over several heredocs.

    Long-running commands: the tool waits a bounded window (2 min default) which is \
    a YIELD, NOT a kill. On elapse the command is MOVED TO THE BACKGROUND still \
    running, and you get a `background_id` — do NOT re-run it. Pass \
    `run_in_background: true` up front for builds, full suites and servers.

    You WILL be notified automatically when a background command finishes, with exit \
    code, output tail and a file path. So do NOT poll: no bash_output "just to \
    check", no `sleep`, no `ls`/`test -f` to see if the artifact landed. Do unrelated \
    work, or stop and let the notification wake you. Call bash_output only for a \
    command you were already told finished, or to kill one early.

    Discovery scans (du, find, ls -R): bound the first pass (`-maxdepth`, `-d 1`), \
    never re-scan ground already covered, and stop once the question is answered. On \
    a non-zero exit or a yield, CHANGE the command — narrow it, exclude the failing \
    path, or use a cheaper tool; never retry a near-identical variant. "Operation not \
    permitted" on system paths is EXPECTED — prune and move on.
    """
  end
end
