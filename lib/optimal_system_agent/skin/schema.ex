defmodule OptimalSystemAgent.Skin.Schema do
  @moduledoc "Skin data structure with validation and defaults."

  @type t :: %__MODULE__{
          name: String.t(),
          display_name: String.t(),
          description: String.t(),
          colors: map(),
          branding: map(),
          meta: map()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    display_name: "",
    description: "",
    colors: %{},
    branding: %{},
    meta: %{}
  ]

  @default_colors %{
    "primary" => "#E5E7EB",
    "secondary" => "#06B6D4",
    "success" => "#22C55E",
    "warning" => "#F59E0B",
    "error" => "#EF4444",
    "muted" => "#6B7280",
    "dim" => "#374151",
    "border" => "#4B5563",
    "msg_border_user" => "#06B6D4",
    "msg_border_agent" => "#E5E7EB",
    "msg_border_system" => "#374151",
    "msg_border_warning" => "#F59E0B",
    "msg_border_error" => "#EF4444",
    "sidebar_bg" => "#1F2937",
    "modal_bg" => "#111827",
    "tooltip_bg" => "#1F2937",
    "input_bg" => "#111827",
    "selection_bg" => "#374151",
    "dialog_bg" => "#1F2937",
    "button_active_bg" => "#E5E7EB",
    "button_active_text" => "#111827",
    "grad_a" => "#E5E7EB",
    "grad_b" => "#06B6D4",
    "diff_del_bg" => "#3C0A0A",
    "diff_add_bg" => "#0A2D14",
    "diff_del_highlight_fg" => "#FF7878",
    "diff_del_highlight_bg" => "#641414",
    "diff_add_highlight_fg" => "#78FF8C",
    "diff_add_highlight_bg" => "#14501E"
  }

  @default_branding %{
    "agent_name" => "OSA Agent",
    "spinner_frames" => [".", "..", "...", "...."],
    "spinner_text" => "Thinking"
  }

  def default_colors, do: @default_colors
  def default_branding, do: @default_branding

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{"name" => name} = data) when is_binary(name) and name != "" do
    skin = %__MODULE__{
      name: name,
      display_name: Map.get(data, "display_name", name),
      description: Map.get(data, "description", ""),
      colors: merge_with_defaults(Map.get(data, "colors", %{}), @default_colors),
      branding: merge_with_defaults(Map.get(data, "branding", %{}), @default_branding),
      meta: Map.get(data, "meta", %{})
    }

    {:ok, skin}
  end

  def from_map(_), do: {:error, "Skin must have a non-empty 'name' field"}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = skin) do
    %{
      "name" => skin.name,
      "display_name" => skin.display_name,
      "description" => skin.description,
      "colors" => skin.colors,
      "branding" => skin.branding,
      "meta" => skin.meta
    }
  end

  defp merge_with_defaults(overrides, defaults) when is_map(overrides) do
    Map.merge(defaults, overrides)
  end

  defp merge_with_defaults(_, defaults), do: defaults
end
