defmodule OptimalSystemAgent.Tools.Builtins.FileWrite.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Mirrors the pattern from `FileRead.Constants`. Other tools' prompts
  (e.g. `FileEdit.Prompt`) can reference `tool_name/0` via `safe_ref/3`
  so a rename propagates everywhere automatically.
  """

  @tool_name "file_write"
  def tool_name, do: @tool_name

  # On macOS `/tmp` is a symlink to `/private/tmp`. The handler resolves
  # symlinks before security checks (anti-traversal), so include both paths
  # so users can write to `/tmp/...` paths without their symlink-resolved
  # form `/private/tmp/...` tripping the allowlist.
  @default_allowed_write_paths ["~", "/tmp", "/private/tmp"]
  def default_allowed_write_paths, do: @default_allowed_write_paths

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

  @soul_reload_files ~w(USER.md IDENTITY.md SOUL.md)
  def soul_reload_files, do: @soul_reload_files
end
