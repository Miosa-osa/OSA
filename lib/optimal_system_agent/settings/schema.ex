defmodule OptimalSystemAgent.Settings.Schema do
  @moduledoc """
  Schema validation for the settings cascade, with a fix tip per error.

  `validate/1` checks a settings map against the known-key registry and
  returns issue maps: `%{key, severity, message, tip}`. Unknown top-level
  keys are NOT flagged (OSA settings are open-world); only type mismatches
  on known keys and JSON parse failures are reported.
  """
  require Logger

  # key => {type, tip}
  @known %{
    "env" => {:string_map, ~s(Use an object of NAME → value strings: {"env": {"FOO": "bar"}})},
    "hooks" =>
      {:map, ~s(Use {"hooks": {"pre_tool_use": [{"type": "shell", "command": "..."}]}})},
    "permissions" =>
      {:map, ~s(Use {"permissions": {"allow": [...], "deny": [...], "ask": [...]}})},
    "model" => {:string, ~s(Use a model id string, e.g. {"model": "glm-4.7:cloud"})},
    "personality" => {:string, "Use a personality name string"},
    "skin" => {:string, ~s(Use a skin name string, e.g. "dark")},
    "effort_level" => {:string, ~s(Use "low" | "medium" | "high")},
    "permission_mode" => {:string, ~s(Use "ask" | "auto-edit" | "plan" | "overdrive")},
    "context_refs_enabled" => {:boolean, "Use true or false (no quotes)"},
    "context_refs_budget" => {:number, "Use a number of tokens, e.g. 30000"},
    "fs_checkpoints_enabled" => {:boolean, "Use true or false (no quotes)"},
    "fs_checkpoints_max_count" => {:number, "Use an integer count"},
    "rewind_checkpoints_max_count" => {:number, "Use an integer count"},
    "skin_engine_enabled" => {:boolean, "Use true or false (no quotes)"},
    "skill_curator_enabled" => {:boolean, "Use true or false (no quotes)"},
    "http_port" => {:number, "Use an integer port, e.g. 9089"}
  }

  @doc "Validate a settings map. Returns [] when clean."
  def validate(settings) when is_map(settings) do
    Enum.flat_map(settings, fn {key, value} ->
      key = to_string(key)

      case Map.fetch(@known, key) do
        {:ok, {type, tip}} ->
          if type_ok?(type, value) do
            []
          else
            [issue(key, :error, "expected #{type_name(type)}, got #{inspect(value)}", tip)]
          end

        :error ->
          []
      end
    end)
  end

  def validate(_),
    do: [
      issue("(root)", :error, "settings root must be a JSON object", "Wrap settings in { ... }")
    ]

  @doc "Validate a settings file on disk: JSON parse errors + schema issues."
  def validate_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} ->
            validate(map)

          {:error, %Jason.DecodeError{position: pos}} ->
            [
              issue(
                Path.basename(path),
                :error,
                "invalid JSON at byte #{pos}",
                "Fix the syntax near that position — check for trailing commas or unquoted keys"
              )
            ]

          {:error, _} ->
            [
              issue(
                Path.basename(path),
                :error,
                "invalid JSON",
                "Check for trailing commas or unquoted keys"
              )
            ]
        end

      {:error, :enoent} ->
        []

      {:error, reason} ->
        [
          issue(
            Path.basename(path),
            :error,
            "unreadable (#{inspect(reason)})",
            "Check file permissions"
          )
        ]
    end
  end

  @doc "Validate every file source and log one warning per issue with its tip. Returns the issues."
  def validate_and_log do
    issues = Enum.flat_map(OptimalSystemAgent.Settings.source_paths(), &validate_file/1)

    Enum.each(issues, fn %{key: key, message: message, tip: tip} ->
      Logger.warning("[settings] #{key}: #{message} — tip: #{tip}")
    end)

    issues
  rescue
    _ -> []
  end

  # ── Private ───────────────────────────────────────────────────────

  defp type_ok?(:string, v), do: is_binary(v)
  defp type_ok?(:boolean, v), do: is_boolean(v)
  defp type_ok?(:number, v), do: is_number(v)
  defp type_ok?(:map, v), do: is_map(v)

  defp type_ok?(:string_map, v),
    do: is_map(v) and Enum.all?(v, fn {k, val} -> is_binary(k) and is_binary(val) end)

  defp type_name(:string_map), do: "an object of string values"
  defp type_name(:map), do: "an object"
  defp type_name(:string), do: "a string"
  defp type_name(:boolean), do: "a boolean"
  defp type_name(:number), do: "a number"

  defp issue(key, severity, message, tip),
    do: %{key: key, severity: severity, message: message, tip: tip}
end
