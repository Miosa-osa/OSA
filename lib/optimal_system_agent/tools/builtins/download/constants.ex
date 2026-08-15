defmodule OptimalSystemAgent.Tools.Builtins.Download.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "download"
  def tool_name, do: @tool_name

  @max_download_bytes 50 * 1024 * 1024
  def max_download_bytes, do: @max_download_bytes

  @max_redirects 3
  def max_redirects, do: @max_redirects

  # Where a RELATIVE download path is rooted. Exported because
  # `Tools.ConflictScope` must expand a declared target against the same root
  # the handler uses — two names for one file that expand differently would
  # compare as distinct, which is precisely the race the scope check exists to
  # catch.
  @workspace_root "~/.osa/workspace"
  def workspace_root, do: @workspace_root

  @default_allowed_write_paths ["~", "/tmp"]
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
end
