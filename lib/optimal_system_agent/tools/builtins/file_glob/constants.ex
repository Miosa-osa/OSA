defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts can reference `tool_name/0` so a rename here
  propagates automatically.
  """

  @tool_name "file_glob"
  def tool_name, do: @tool_name

  @default_allowed_paths ["~", "/tmp"]
  def default_allowed_paths, do: @default_allowed_paths

  @sensitive_paths [
    ".ssh/id_rsa",
    ".ssh/id_ed25519",
    ".ssh/id_ecdsa",
    ".ssh/id_dsa",
    ".gnupg/",
    ".aws/credentials",
    ".env",
    "/etc/shadow",
    "/etc/sudoers",
    "/etc/master.passwd",
    ".netrc",
    ".npmrc",
    ".pypirc"
  ]
  def sensitive_paths, do: @sensitive_paths

  @max_results 200
  def max_results, do: @max_results

  @max_suggestions 3
  def max_suggestions, do: @max_suggestions

  @doc """
  Directories whose contents are noise in every ordinary search.

  Only relevant because `file_glob` walks dot-directories (`match_dot: true`).
  Without this, a plain `**/*` in any repository returns a few thousand loose
  objects under `.git/` and nothing else survives the result cap — the dotfile
  fix would have cost more than it bought. The filter is skipped whenever the
  caller names the directory in the pattern, so `.git/**` still works.
  """
  @noise_dirs [".git"]
  def noise_dirs, do: @noise_dirs
end
