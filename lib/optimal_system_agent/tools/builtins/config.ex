defmodule OptimalSystemAgent.Tools.Builtins.Config do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Settings

  @impl true
  def name, do: "config"

  @impl true
  def deferred?, do: true

  @impl true
  def description do
    "Read or write OSA configuration settings.\n\n" <>
      "Actions:\n" <>
      "- `get` — read a setting value (resolved through cascade: session → local → project → user)\n" <>
      "- `set` — write a setting value to a specific layer\n" <>
      "- `list` — show all settings merged\n\n" <>
      "Common settings: default_provider, effort_level, max_context_tokens, temperature,\n" <>
      "plan_mode_enabled, thinking_enabled, interactive_permissions"
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["get", "set", "list"],
          "description" => "Action to perform"
        },
        "key" => %{
          "type" => "string",
          "description" => "Setting key (for get/set)"
        },
        "value" => %{
          "type" => "string",
          "description" => "Setting value (for set)"
        },
        "layer" => %{
          "type" => "string",
          "enum" => ["user", "project", "session"],
          "description" => "Which settings layer to write to (default: session)"
        }
      }
    }
  end

  @impl true
  def execute(%{"action" => "get", "key" => key}) do
    value = Settings.get(String.to_atom(key))

    if value != nil do
      {:ok, "#{key} = #{inspect(value)}"}
    else
      {:ok, "#{key} is not set (using default)"}
    end
  rescue
    _ -> {:ok, "Setting not found: #{key}"}
  end

  def execute(%{"action" => "set", "key" => key, "value" => value} = args) do
    layer = Map.get(args, "layer", "session")
    parsed_value = parse_value(value)

    case layer do
      "session" ->
        Settings.set_session(String.to_atom(key), parsed_value)
        {:ok, "Set #{key} = #{inspect(parsed_value)} (session-level, not persisted)"}

      "user" ->
        Settings.set_user(key, parsed_value)
        {:ok, "Set #{key} = #{inspect(parsed_value)} (user-level, saved to ~/.osa/settings.json)"}

      "project" ->
        Settings.set_project(key, parsed_value)

        {:ok,
         "Set #{key} = #{inspect(parsed_value)} (project-level, saved to .osa/settings.json)"}

      _ ->
        {:error, "Unknown layer: #{layer}. Use session, user, or project."}
    end
  end

  def execute(%{"action" => "list"}) do
    all = Settings.all()

    if map_size(all) == 0 do
      {:ok, "No custom settings configured. Using defaults."}
    else
      formatted =
        Enum.map(all, fn {k, v} ->
          "  #{k}: #{inspect(v)}"
        end)
        |> Enum.sort()
        |> Enum.join("\n")

      {:ok, "Current settings (merged):\n#{formatted}"}
    end
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}. Use get, set, or list."}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}

  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(v) do
    case Integer.parse(v) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(v) do
          {f, ""} -> f
          _ -> v
        end
    end
  end
end
