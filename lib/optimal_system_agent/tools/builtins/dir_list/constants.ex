defmodule OptimalSystemAgent.Tools.Builtins.DirList.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts (e.g. `FileRead.Prompt`) reference `tool_name/0` so a
  rename here propagates automatically across all prompt strings.
  """

  @tool_name "dir_list"
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
end
