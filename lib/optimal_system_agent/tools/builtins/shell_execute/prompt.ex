defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.Prompt do
  @moduledoc """
  Dynamic prompt for `shell_execute`.

  Routing, batching and the answer-with-a-program habit are stated ONCE in
  SYSTEM.md §5 and are deliberately absent here. The permission-segmentation
  contract lives on the `command` parameter and the yield/background contract on
  `run_in_background`, next to the schema they constrain. What is left is the one
  thing a model reliably gets wrong about this tool: that a yielded command is
  still alive, and that a backgrounded server is not.
  """

  @doc """
  Render the shell_execute tool prompt.

  `opts` is reserved for future signal-aware customization.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Executes a shell command and returns its output. Use it for system commands \
    (git, mix, npm, cargo, docker, make) and to compute answers about the tree.

    A foreground command that outruns the wait window (2 min default) is NOT \
    killed. That is a YIELD, NOT a kill: the command MOVES TO THE BACKGROUND \
    still running and you are given a `background_id`, so do NOT re-run it — \
    collect it with `bash_output`.

    Servers are a THIRD case: a background command dies with the session. If the \
    task asks for a service still listening after you finish, daemonise it out of \
    the session yourself — `setsid nohup <cmd> </dev/null >/tmp/<name>.log 2>&1 &` \
    — then VERIFY it independently (`curl`, `ss -ltnp`) and say you left it running.
    """
  end
end
