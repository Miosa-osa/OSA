defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Mirrors `src/tools/FileEditTool/constants.ts`. Other tools' prompts
  reference `tool_name/0` so a rename here propagates everywhere
  automatically.
  """

  @tool_name "file_edit"
  def tool_name, do: @tool_name

  # Paths that are allowed as both read and write targets (same set as FileRead
  # so that the "read before edit" invariant can always succeed on allowed files).
  @default_allowed_paths ["~", "/tmp"]
  def default_allowed_paths, do: @default_allowed_paths

  # Files that must never be read from (symlink-traversal & credential guard).
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

  # Paths that must never be written to (OS / system directories).
  @blocked_write_paths [
    ".ssh/",
    ".gnupg/",
    "/etc/",
    "/boot/",
    "/usr/",
    "/bin/",
    "/sbin/",
    "/var/",
    ".aws/",
    ".env"
  ]
  def blocked_write_paths, do: @blocked_write_paths
end
