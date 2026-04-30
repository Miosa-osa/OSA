defmodule OptimalSystemAgent.Tools.Builtins.Config.Prompt do
  @moduledoc """
  Dynamic prompt for `config`.

 The prompt
  body is a function so it can be extended with dynamic setting lists in
  the future.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Read or write OSA configuration settings.

    View or change OSA settings. Use when the user requests configuration changes,
    asks about current settings, or when adjusting a setting would benefit them.

    ## Usage
    - **Get current value:** `{"action": "get", "key": "setting_name"}`
    - **Set new value:** `{"action": "set", "key": "setting_name", "value": "value"}`
    - **List all settings:** `{"action": "list"}`

    ## Actions
    - `get`  — read a setting value (resolved through cascade: session → local → project → user)
    - `set`  — write a setting value to a specific layer (default: session)
    - `list` — show all settings merged across all layers

    ## Layers
    - `session`  — not persisted, resets when session ends
    - `user`     — saved to `~/.osa/settings.json`
    - `project`  — saved to `.osa/settings.json`

    ## Common settings
    `default_provider`, `effort_level`, `max_context_tokens`, `temperature`,
    `plan_mode_enabled`, `thinking_enabled`, `interactive_permissions`

    ## Examples
    - Get provider: `{"action": "get", "key": "default_provider"}`
    - Set temperature: `{"action": "set", "key": "temperature", "value": "0.7"}`
    - List all: `{"action": "list"}`
    """
  end
end
