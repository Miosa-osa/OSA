defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Prompt do
  @moduledoc """
  Dynamic prompt for `code_symbols`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    file_read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    """
    Find a definition in a source file, without reading the file.

    With `name`: returns the source of that one function or class and its line
    range — the definition, not a guessed window around it. This is the call to
    make instead of grepping for `def foo` and then reading 40 lines near the
    hit; it costs the definition, not the file.

    Without `name`: lists every function, class and module defined in the file,
    with line numbers.

    `path` must be absolute, and only this file is examined — a name defined
    elsewhere will not be found. Languages: C/C++, Python, JavaScript/TypeScript,
    Go, Rust, Ruby, Java/Kotlin, Elixir, shell. For full file contents use
    `#{file_read_name}` instead.
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
