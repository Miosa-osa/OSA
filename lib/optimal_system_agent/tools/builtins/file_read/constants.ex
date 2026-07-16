defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

 Other tools' prompts
  (`FileEdit.Prompt`, `FileWrite.Prompt`) reference `tool_name/0` so a
  rename here propagates everywhere automatically.
  """

  @tool_name "file_read"
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

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .bmp .tiff)
  def image_extensions, do: @image_extensions

  @max_image_bytes 10 * 1024 * 1024
  def max_image_bytes, do: @max_image_bytes

  # Cap for whole-file plain-text reads. Without a guard, `File.read` on a
  # multi-GB file allocates the entire contents into one BEAM binary before any
  # truncation, OOM-pressuring the whole node. Slices via offset/limit are
  # streamed and unaffected.
  @max_read_bytes 20 * 1024 * 1024
  def max_read_bytes, do: @max_read_bytes
end
