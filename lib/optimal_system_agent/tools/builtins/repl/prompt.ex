defmodule OptimalSystemAgent.Tools.Builtins.REPL.Prompt do
  @moduledoc """
  Dynamic prompt for `repl`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Execute code in an interactive REPL session.

    Supports Python, Elixir (iex), and Node.js. The session persists across calls —
    variables and state carry over between executions within the same session.

    Use for:
    - Quick code validation without creating files
    - Data processing and exploration
    - Testing code snippets before writing to files
    - Mathematical calculations
    """
  end
end
