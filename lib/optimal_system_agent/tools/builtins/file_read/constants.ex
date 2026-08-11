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
    # Subscription bearer tokens for the operator's paid accounts. An agent
    # that can read its own credential store is an exfiltration primitive:
    # one prompt-injected instruction in a file it was asked to summarise is
    # enough to get the token into a tool call. Denied by name, alongside the
    # other credential stores above.
    ".osa/subscriptions.json",
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

  # Per-line character cap. `offset`/`limit` bound the number of lines but not
  # their width, so a single minified or base64 line can be megabytes on its own
  # and blow the transport budget no matter how small a slice was requested.
  # See `FileRead.Lines`.
  @max_line_chars 2_000
  def max_line_chars, do: @max_line_chars

  # How much of a file's head is handed to `FileRead.Magic` for type sniffing.
  # Every signature it knows lives within the first 262 bytes; the rest is
  # headroom for the NUL/UTF-8 heuristic to see representative content.
  @sniff_bytes 4_096
  def sniff_bytes, do: @sniff_bytes

  # How many near-miss filenames to offer when a path does not exist. Three is
  # enough to cover a typo, a wrong extension and a sibling; more is noise.
  @max_suggestions 3
  def max_suggestions, do: @max_suggestions
end
