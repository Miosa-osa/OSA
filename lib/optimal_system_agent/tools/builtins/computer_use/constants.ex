defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Constants do
  @moduledoc """
  Exported constants for cross-tool reference.

  Other tools' prompts can reference `tool_name/0` so a rename propagates
  automatically. Action atoms are exported for the handler and tests to share
  a single authoritative list.
  """

  @tool_name "computer_use"
  def tool_name, do: @tool_name

  @valid_actions ~w(screenshot click double_click type key scroll move_mouse drag get_tree)a
  def valid_actions, do: @valid_actions

  @valid_scroll_directions ~w(up down left right)
  def valid_scroll_directions, do: @valid_scroll_directions

  # Maximum bytes accepted for the `text` parameter on type/key actions.
  @max_text_bytes 4_096
  def max_text_bytes, do: @max_text_bytes

  # Maximum length for a key combo string (characters).
  @max_key_combo_len 120
  def max_key_combo_len, do: @max_key_combo_len

  # Pattern for valid key combos (e.g. "ctrl+c", "shift+F4", "super+space").
  @key_combo_pattern ~r/^[a-zA-Z0-9+\-_ ]+$/
  def key_combo_pattern, do: @key_combo_pattern

  # ETS table used by the lazy-server registry.
  @server_table :computer_use_servers
  def server_table, do: @server_table
end
