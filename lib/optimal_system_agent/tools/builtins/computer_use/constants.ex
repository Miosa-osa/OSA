defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Constants do
  @moduledoc """
  Exported constants for cross-tool reference.

  Other tools' prompts can reference `tool_name/0` so a rename propagates
  automatically. Action atoms are exported for the handler and tests to share
  a single authoritative list.
  """

  @tool_name "computer_use"
  def tool_name, do: @tool_name

  @valid_actions ~w(
    screenshot click double_click type key scroll move_mouse drag get_tree
    wait list_windows focus_window launch cursor snapshot right_click triple_click
    set_value clipboard_get clipboard_set clipboard_clear list_apps list_surfaces
    resize_window move_window scroll_to
    left_click mouse_move middle_click left_mouse_down left_mouse_up hold_key
    left_click_drag cursor_position
  )a
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
  #
  # CHARACTER-SET ONLY. This says the string cannot inject shell metacharacters
  # when interpolated into an xdotool/ydotool command line. It says NOTHING
  # about whether the combo is safe to press — `ctrl+alt+del`, `super+l` and
  # `alt+F4` are all made of these characters. See `destructive_combo?/1`.
  @key_combo_pattern ~r/^[a-zA-Z0-9+\-_ ]+$/
  def key_combo_pattern, do: @key_combo_pattern

  # ── Destructive key combinations ───────────────────────────────────────
  #
  # Combos that end the session, kill the display server, force-quit an app,
  # switch virtual terminals, or reboot the machine. Every one of these is
  # unrecoverable-from-inside: once pressed, the agent has no way to undo it
  # and typically no way to observe the result either (the screen it would
  # screenshot is gone). They are denied outright rather than routed through a
  # permission prompt, because there is no legitimate automation reason to
  # synthesize them and the prompt itself may be what gets dismissed.
  #
  # Matching is normalized: case-folded, whitespace-stripped, aliases resolved
  # (`cmd`/`win`/`meta` → `super`, `del` → `delete`, `esc` → `escape`, `return`
  # → `enter`), and modifier order ignored — so `Alt + F4`, `F4+alt` and
  # `alt+f4` are the same entry.
  @destructive_combos [
    # Session / login manager
    ~w(ctrl alt delete),
    ~w(ctrl alt backspace),
    ~w(ctrl alt end),
    ~w(super l),
    ~w(ctrl alt l),
    ~w(super escape),
    ~w(ctrl shift power),
    ~w(super shift e),
    ~w(super shift q),
    ~w(ctrl alt shift q),
    # Force-quit / close
    ~w(alt f4),
    ~w(super q),
    ~w(super alt escape),
    ~w(super option escape),
    ~w(ctrl q),
    ~w(ctrl alt q),
    # macOS shutdown / force-quit / lock
    ~w(ctrl super q),
    ~w(ctrl super power),
    ~w(ctrl super eject),
    ~w(super ctrl q),
    ~w(super power),
    # Magic SysRq (Linux: REISUB et al.)
    ~w(alt sysrq),
    ~w(alt printscreen),
    ~w(alt print),
    # Power keys pressed alone
    ~w(power),
    ~w(poweroff),
    ~w(xf86poweroff),
    ~w(xf86sleep),
    ~w(xf86suspend)
  ]

  # Virtual-terminal switches: ctrl+alt+F1 … ctrl+alt+F12 yank the graphical
  # session away. Generated rather than listed so no F-key is missed.
  @vt_switch_combos for n <- 1..12, do: ["ctrl", "alt", "f#{n}"]

  @all_destructive_combos Enum.map(@destructive_combos ++ @vt_switch_combos, &Enum.sort/1)
  def destructive_combos, do: @all_destructive_combos

  @key_aliases %{
    "cmd" => "super",
    "command" => "super",
    "win" => "super",
    "windows" => "super",
    "meta" => "super",
    "mod4" => "super",
    "super_l" => "super",
    "super_r" => "super",
    "control" => "ctrl",
    "ctl" => "ctrl",
    "ctrl_l" => "ctrl",
    "ctrl_r" => "ctrl",
    "alt_l" => "alt",
    "alt_r" => "alt",
    "altgr" => "alt",
    "option" => "alt",
    "opt" => "alt",
    "shift_l" => "shift",
    "shift_r" => "shift",
    "del" => "delete",
    "esc" => "escape",
    "return" => "enter",
    "bksp" => "backspace",
    "bs" => "backspace",
    "prtsc" => "printscreen",
    "prtscr" => "printscreen",
    "sysrq" => "sysrq",
    "prior" => "pageup",
    "next" => "pagedown"
  }

  @doc """
  Normalize a key combo into a sorted list of canonical key tokens.

  Case-folded, alias-resolved, order-independent — so a denylist entry cannot
  be evaded by reordering modifiers or spelling `cmd` for `super`.
  """
  @spec normalize_combo(String.t()) :: [String.t()]
  def normalize_combo(combo) when is_binary(combo) do
    combo
    |> String.downcase()
    |> String.split(["+", "-", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Map.get(@key_aliases, &1, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def normalize_combo(_), do: []

  @doc """
  True when the combo is on the destructive denylist.

  Note the `-` split in `normalize_combo/1`: some callers write `ctrl-alt-del`.
  A consequence is that a literal `-` key (`minus`) is not expressible as a
  bare token, which is why `minus` is the spelling to use for that key.
  """
  @spec destructive_combo?(String.t()) :: boolean()
  def destructive_combo?(combo) when is_binary(combo) do
    normalize_combo(combo) in @all_destructive_combos
  end

  def destructive_combo?(_), do: false

  # ETS table used by the lazy-server registry.
  @server_table :computer_use_servers
  def server_table, do: @server_table
end
