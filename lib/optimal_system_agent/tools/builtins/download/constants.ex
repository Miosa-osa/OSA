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
