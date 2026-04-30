defmodule OptimalSystemAgent.Tools.Builtins.SendUserFile.Constants do
  @moduledoc "Exported constants for the send_user_file tool."

  @tool_name "send_user_file"
  def tool_name, do: @tool_name

  # Maximum file size to attach inline in the event payload (bytes)
  # Larger files get a path reference only
  @inline_size_limit_bytes 512 * 1_024
  def inline_size_limit_bytes, do: @inline_size_limit_bytes

  # Valid MIME types for inline preview (subset — others pass as path-only)
  @previewable_extensions ~w(.txt .md .log .json .yaml .yml .toml .csv .sh .ex .exs .py .js .ts .go .rb .rs)
  def previewable_extensions, do: @previewable_extensions

  # Event type emitted on the Events.Bus
  @event_type :system_event
  def event_type, do: @event_type

  # Subtype key in the payload that the frontend keys off
  @subtype "send_user_file"
  def subtype, do: @subtype
end
