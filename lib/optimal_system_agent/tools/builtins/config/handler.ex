defmodule OptimalSystemAgent.Tools.Builtins.Config.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `config`.

  Behaviour split:
    * `validate/2`           — checks input shape (action required; key/value for set)
    * `check_permissions/2`  — always allowed
    * `execute/2`            — delegates to Settings module

  Action semantics:
    * `get` / `list` — read-only; called by `read_only?/2` in Tool
    * `set`          — write; layer-scoped persistence
  """

  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Tools.Builtins.Config.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx)
      when action in ["get", "list", "set"] do
    if action == "set" and not (Map.has_key?(input, "key") and Map.has_key?(input, "value")) do
      {:error, "set action requires key and value parameters", -32_602}
    else
      {:ok, input}
    end
  end

  def validate(%{"action" => action}, _ctx) do
    {:error,
     "Unknown action: #{action}. Valid actions: #{Enum.join(Constants.read_actions() ++ Constants.write_actions(), ", ")}",
     -32_602}
  end

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) :: {:allow, map()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "get", "key" => key}, _ctx) do
    value = Settings.get(String.to_atom(key))

    if value != nil do
      {:ok, "#{key} = #{inspect(value)}"}
    else
      {:ok, "#{key} is not set (using default)"}
    end
  rescue
    _ -> {:ok, "Setting not found: #{key}"}
  end

  def execute(%{"action" => "set", "key" => key, "value" => value} = args, _ctx) do
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

  def execute(%{"action" => "list"}, _ctx) do
    all = Settings.all()

    if map_size(all) == 0 do
      {:ok, "No custom settings configured. Using defaults."}
    else
      formatted =
        all
        |> Enum.map(fn {k, v} -> "  #{k}: #{inspect(v)}" end)
        |> Enum.sort()
        |> Enum.join("\n")

      {:ok, "Current settings (merged):\n#{formatted}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

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
