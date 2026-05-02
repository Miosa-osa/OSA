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
      - Not available on MIOSA REST computers; use `screenshot` there.

    **wait** — Pause server-side for `seconds` (0–30).

    **list_windows** — Return open windows. MIOSA REST computers only.

    **focus_window** — Focus a MIOSA window by `window_id`.

    **launch** — Launch an application by `app` name or command.

    **cursor** — Return the current mouse cursor coordinates. MIOSA REST computers only.

    **snapshot** — Return an AI-friendly UI snapshot with refs when the MIOSA computer supports it.
      - Optional filters: `app`, `window_id`, `surface`, `root`, `max_depth`, `interactive_only`, `compact`.

    **right_click** / **triple_click** — Click at `x`/`y` or a MIOSA snapshot `target` ref.

    **set_value** — Set an element value using `target` or `x`/`y` plus `text`.

    **clipboard_get** / **clipboard_set** / **clipboard_clear** — Read, write, or clear text clipboard.

    **list_apps** — Return running or launchable applications when supported by the MIOSA computer.

    **list_surfaces** — Return observable surfaces such as windows, menus, sheets, popovers, or alerts.

    **resize_window** / **move_window** — Change a MIOSA window by `window_id`.

    **scroll_to** — Scroll an element or coordinate into view.

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
      - MIOSA: REST API for cloud computers and OpenComputers (`computer_use_platform: :miosa`)

    Computer use is only available when `computer_use_enabled: true` is set in
    the OSA application config.
    """
  end
end
