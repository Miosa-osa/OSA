defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "multi_file_edit"
  def tool_name, do: @tool_name

  @default_allowed_paths ["~", "/tmp"]
  def default_allowed_paths, do: @default_allowed_paths

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
