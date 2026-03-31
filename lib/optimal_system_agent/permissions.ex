defmodule OptimalSystemAgent.Permissions do
  @moduledoc """
  Permission rule persistence and evaluation.

  Rules are stored in `~/.osa/permissions.json` and loaded at boot.
  Each rule maps a tool name to an action: `:allow` or `:deny`.

  Rules are checked before the interactive prompt — if a matching
  "allow always" rule exists, the prompt is skipped entirely.
  """

  @permissions_file Path.expand("~/.osa/permissions.json")

  @doc "Check if a tool is pre-approved by saved rules."
  def check(tool_name, _args \\ %{}) do
    rules = load_rules()

    case Map.get(rules, tool_name) do
      "allow" -> :allow
      "deny" -> :deny
      _ -> :ask
    end
  end

  @doc "Save a permission rule (allow_always or deny)."
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

  defp load_rules do
    case File.read(@permissions_file) do
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
    dir = Path.dirname(@permissions_file)
    File.mkdir_p!(dir)

    content = Jason.encode!(rules, pretty: true)
    File.write!(@permissions_file, content)
  rescue
    _ -> :ok
  end
end
