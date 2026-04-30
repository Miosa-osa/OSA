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
    """
  end
end
