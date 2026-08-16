defmodule OptimalSystemAgent.Tools.Builtins.DirList.Prompt do
  @moduledoc """
  Dynamic prompt for `dir_list`.

  Routing to `file_read` / `file_glob` is stated once in SYSTEM.md §5, so this
  description carries only the output format, which nothing else can state.
  """

  @doc """
  Render the dir_list tool prompt.

  `opts` is reserved for future signal-aware customization.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Lists files and directories at an absolute path (omit or pass "." for the
    cwd). Does not recurse. Output is a `<directory> — <n> entries` header, then
    one `<type>\\t<size>\\t<name>` line per entry (type `dir`/`file`/raw fs type;
    size B/K/M, `-` for directories). Dotfiles are included; an empty directory
    reports itself rather than returning empty.
    """
  end

end
