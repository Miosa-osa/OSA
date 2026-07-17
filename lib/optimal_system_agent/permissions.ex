defmodule OptimalSystemAgent.Permissions do
  @moduledoc """
  Permission rule persistence and evaluation.

  Rules are stored in `~/.osa/permissions.json` and loaded at boot.
  Each rule maps a tool name to an action: `:allow` or `:deny`.

  Rules are checked before the interactive prompt — if a matching
  "allow always" rule exists, the prompt is skipped entirely.
  """

  @default_permissions_file Path.expand("~/.osa/permissions.json")

  # Resolved at call time (not compile time) so tests can redirect the rule
  # store to a tmp path via `config :optimal_system_agent, :permissions_file`
  # and never touch the real ~/.osa file.
  defp permissions_file do
    Application.get_env(:optimal_system_agent, :permissions_file, @default_permissions_file)
  end

  @doc """
  Check if a tool call is pre-approved by saved rules.

  Supports two rule formats:
  - Simple: `"shell_execute" => "allow"` — matches any call to that tool
  - Pattern: `"shell_execute:git *" => "allow"` — matches only when args match the pattern

  Pattern matching uses glob-style wildcards on the first argument value.
  Examples:
  - `"shell_execute:git *"` — allow any git command
  - `"file_edit:lib/**"` — allow edits to any file under lib/
  - `"file_write:*.test.*"` — allow writing test files
  """
  def check(tool_name, args \\ %{}) do
    rules = load_rules()

    # Check pattern rules first (most specific wins)
    pattern_result =
      rules
      |> Enum.filter(fn {key, _val} -> String.contains?(key, ":") end)
      |> Enum.find_value(fn {key, action} ->
        [rule_tool, pattern] = String.split(key, ":", parts: 2)

        if rule_tool == tool_name and matches_pattern?(pattern, args) do
          case action do
            "allow" -> :allow
            "deny" -> :deny
            _ -> nil
          end
        end
      end)

    if pattern_result do
      pattern_result
    else
      # Fall back to simple tool-name rules
      case Map.get(rules, tool_name) do
        "allow" -> :allow
        "deny" -> :deny
        _ -> :ask
      end
    end
  end

  @doc """
  Save a permission rule.

  Supports pattern rules: `save_rule("shell_execute:git *", :allow_always)`
  """
  def save_rule(tool_name, decision) do
    rules = load_rules()

    action =
      case decision do
        :allow_always -> "allow"
        :deny_always -> "deny"
        _ -> nil
      end

    if action do
      updated = Map.put(rules, tool_name, action)
      write_rules(updated)
    end
  end

  @doc "List all saved permission rules."
  def list_rules do
    load_rules()
  end

  @doc "Remove a saved permission rule."
  def remove_rule(tool_name) do
    rules = load_rules()
    updated = Map.delete(rules, tool_name)
    write_rules(updated)
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Match a glob pattern against tool arguments.
  # Extracts the primary argument (command for shell_execute, path for file ops)
  # and matches it against the pattern.
  defp matches_pattern?(pattern, args) when is_map(args) do
    # Extract the primary value to match against
    primary =
      Map.get(args, "command") ||
        Map.get(args, "path") ||
        Map.get(args, "query") ||
        Map.get(args, "task") ||
        args |> Map.values() |> List.first()

    if is_binary(primary) do
      glob_match?(pattern, primary)
    else
      false
    end
  end

  defp matches_pattern?(_pattern, _args), do: false

  # Simple glob matching: * matches any sequence within a segment, ** matches across segments
  defp glob_match?(pattern, value) do
    regex_str =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("**", "<<<GLOBSTAR>>>")
      |> String.replace("*", "[^/]*")
      |> String.replace("<<<GLOBSTAR>>>", ".*")

    case Regex.compile("^#{regex_str}$") do
      {:ok, regex} -> Regex.match?(regex, value)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp load_rules do
    case File.read(permissions_file()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, rules} when is_map(rules) -> rules
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp write_rules(rules) do
    file = permissions_file()
    dir = Path.dirname(file)
    File.mkdir_p!(dir)

    content = Jason.encode!(rules, pretty: true)
    File.write!(file, content)
  rescue
    _ -> :ok
  end
end
