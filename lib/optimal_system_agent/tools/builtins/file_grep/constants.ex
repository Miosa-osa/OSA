defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Mirrors the pattern established by `FileRead.Constants`.
  Other tools' prompts reference `tool_name/0` so a rename propagates
  automatically.
  """

  @tool_name "file_grep"
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

  # Generous but bounded — grep can return large outputs when searching
  # broad directories with context lines enabled.
  @max_output_bytes 100_000
  def max_output_bytes, do: @max_output_bytes

  # Legacy per-file truncation kept for the fallback path.
  @max_fallback_files 500
  def max_fallback_files, do: @max_fallback_files

  @default_max_results 50
  def default_max_results, do: @default_max_results
end
