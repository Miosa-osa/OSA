defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Prompt do
  @moduledoc """
  Dynamic prompt for `code_symbols`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    file_read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    """
    Read one definition out of a source file, without reading the file.

    With `name`: the source of that one function or class plus its line range —
    the definition, not a guessed window around it. Make this call instead of
    grepping for `def foo` and then reading 40 lines near the hit.

    Without `name`: every function, class and module in the file, with line
    numbers.

    Absolute `path`, and only that one file is examined. C/C++, Python, JS/TS,
    Go, Rust, Ruby, Java/Kotlin, Elixir, shell. Whole files: `#{file_read_name}`.
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
