defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.AppAllowlist do
  @moduledoc """
  Shared strict allowlist of launchable applications for computer_use.

  Both the PPEV `Executor` and the CLI `ComputerUseDispatch` fast-path resolve
  the `launch`/`launch_app` app name through this module. App names arrive
  straight from LLM tool output, so they must NEVER be handed to `System.cmd`
  without passing `allowed?/1` first (P0: arbitrary-binary-execution guard).
  """

  @allowed_apps ~w(firefox chromium chromium-browser google-chrome google-chrome-stable
    nautilus thunar nemo pcmanfm gnome-terminal xterm konsole alacritty kitty
    gnome-text-editor gedit kate mousepad nano vim code subl
    libreoffice evince eog gimp inkscape vlc mpv totem rhythmbox
    gnome-calculator gnome-system-monitor htop)

  @doc "The canonical list of permitted application binaries."
  @spec allowed_apps() :: [String.t()]
  def allowed_apps, do: @allowed_apps

  @doc "Return true only when `app` is an exact match in the allowlist."
  @spec allowed?(term()) :: boolean()
  def allowed?(app) when is_binary(app), do: app in @allowed_apps
  def allowed?(_), do: false
end
