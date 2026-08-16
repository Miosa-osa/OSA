defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.Prompt do
  @moduledoc """
  Dynamic prompt for `file_edit`.

  The prompt body is a function
  (not a static string) so it can reference *current* tool names — when
  `file_read` is renamed, this prompt updates automatically through the
  `safe_ref/3` helper.

  The first bullet names `file_transform` deliberately. `file_edit` is the tool
  that must lose share to it (see `docs/design/context-free-edits.md` §5), and
  the instruction only works if it sits at the affordance being competed with,
  not only in SYSTEM.md. It is written to route, not to sell: `file_edit`
  remains correct whenever the change needs the surrounding bytes.
  """

  @doc """
  Render the file_edit tool prompt.

  `opts` is currently unused but reserved for future signal-aware
  customization.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    read_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.FileRead.Constants,
        :tool_name,
        "file_read"
      )

    transform_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.FileTransform.Constants,
        :tool_name,
        "file_transform"
      )

    """
    Replaces an exact string in a file.

    If you can name the change by an ANCHOR instead of exact bytes — a pattern, a
    matching line, the end of the file — use `#{transform_name}`: it needs no
    `#{read_name}` and never quotes the file, so its cost does not grow with file
    size. Use this tool when the change needs the surrounding bytes to be
    unambiguous.

    The edit FAILS if `old_string` is not unique — add surrounding context, or set
    `replace_all` to change every instance.
    """
  end

  # Lazy cross-tool name reference. If the target tool's Constants module
  # exists and exports the requested function, use the live value;
  # otherwise fall back to a literal default. Mirrors the lazy-require
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
