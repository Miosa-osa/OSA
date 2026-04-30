defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts reference `tool_name/0` so a rename here propagates
  everywhere automatically.
  """

  @tool_name "notebook_edit"
  def tool_name, do: @tool_name

  @actions ~w(read add_cell edit_cell delete_cell move_cell)
  def actions, do: @actions

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

  # Maximum source size (bytes) for a single cell before the handler warns.
  @max_cell_bytes 512 * 1024
  def max_cell_bytes, do: @max_cell_bytes
end
