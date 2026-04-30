defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Prompt do
  @moduledoc """
  Dynamic prompt for `computer_use`.

  Covers all supported actions and hints at adapter selection so the model
  understands the platform-specific routing that happens under the hood.
  """

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    actions = Constants.valid_actions() |> Enum.map(&to_string/1) |> Enum.join(", ")

    """
    Control the computer desktop via platform-native automation.

    Supported actions: #{actions}

    ## Actions

    **screenshot** — Capture the full screen or a region.
      - Optional `region` object: `{x, y, width, height}` (all non-negative integers; width/height > 0).
      - Returns an image payload the model can inspect for visual context.

    **click** — Single left-click at coordinates or an accessibility element ref.
      - Provide `x` + `y` (non-negative integers), OR
      - Provide `target` (element ref from `get_tree`, e.g. `"e3"`).

    **double_click** — Double-click at `x`, `y` (required).

    **type** — Type a string of text into the focused element.
      - `text` (required): string, 1–#{Constants.max_text_bytes()} bytes.

    **key** — Press a key or key combination.
      - `text` (required): combo string, e.g. `"ctrl+c"`, `"super+space"`, `"F4"`.
      - Allowed characters: letters, digits, `+`, `-`, `_`, space. Max #{Constants.max_key_combo_len()} chars.

    **scroll** — Scroll the view.
      - `direction` (required): one of `up`, `down`, `left`, `right`.

    **move_mouse** — Move the pointer without clicking.
      - `x`, `y` required.

    **drag** — Click-and-drag from `x`, `y`.
      - `x`, `y` required. Use `region` to specify the drag target area if needed.

    **get_tree** — Return the accessibility element tree for the current screen.
      - Use element refs from the tree as `target` for click actions.

    ## Parameters

    - `window` (optional): Window name/title to focus before executing the action.
      Only effective on Linux X11 via xdotool. Silently skipped on other platforms.

    ## Adapter selection

    The platform adapter is selected automatically:
      - macOS: AppleScript/Quartz event injection
      - Linux X11: xdotool + scrot
      - Docker/headless: virtual framebuffer (Xvfb)
      - Remote SSH: tunnelled X11 or platform VM adapter
      - Platform VM: OSA compute layer integration

    Computer use is only available when `computer_use_enabled: true` is set in
    the OSA application config.
    """
  end
end
