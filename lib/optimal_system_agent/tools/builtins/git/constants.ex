defmodule OptimalSystemAgent.Tools.Builtins.Git.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Mirrors the pattern established in `FileRead.Constants`. Other tools'
  prompts reference `tool_name/0` so a rename propagates everywhere
  automatically.
  """

  @tool_name "git"
  def tool_name, do: @tool_name

  # Subcommands that are always read-only — no side-effects on the working tree.
  @read_only_subcommands ~w(status diff log show branch tag remote blame shortlog describe reflog)
  def read_only_subcommands, do: @read_only_subcommands

  # Flag patterns that, when present in any invocation, indicate a destructive op.
  @destructive_flag_patterns ["--force", "-f", "--force-with-lease", "-D", "--hard"]
  def destructive_flag_patterns, do: @destructive_flag_patterns

  # Subcommand + arg combinations that are unconditionally destructive.
  # Format: {subcommand, required_arg_substring}
  @destructive_combinations [
    {"reset", "--hard"},
    {"push", "--force"},
    {"push", "-f"},
    {"push", "--force-with-lease"},
    {"branch", "-D"},
    {"clean", "-f"},
    {"checkout", "."},
    {"restore", "."}
  ]
  def destructive_combinations, do: @destructive_combinations

  # Maximum bytes returned to the model before truncation.
  @max_output_bytes 5_000
  def max_output_bytes, do: @max_output_bytes
end
