defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.Prompt do
  @moduledoc """
  Dynamic prompt for `file_grep`.

  Routing (grep-not-shell, code_symbols for a definition) and batching are
  stated once in SYSTEM.md §5. What is left here is the search semantics a
  model cannot infer: that a "No matches found." has already retried across
  ignored and hidden files.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Search file contents for a regex pattern. Supports full regex syntax
    (e.g. "log.*Error", "function\\\\s+\\\\w+"). Ignored and hidden files are
    searched too when the ordinary search finds nothing, so "No matches found."
    means the pattern is absent, not filtered.
    """
  end

end
