defmodule OptimalSystemAgent.Tools.Builtins.TeamCreate.UI do
  @moduledoc "Render maps for the Rust TUI."

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, input, _opts) when is_map(input) do
    %{
      kind: "team_create",
      name: Map.get(input, "name"),
      member_count: length(Map.get(input, "members", []))
    }
  end

  def render(:tool_result, msg, _opts) when is_binary(msg) do
    %{kind: "team_create_result", message: msg}
  end

  def render(:rejected, reason, _opts) when is_binary(reason) do
    %{kind: "team_create_rejected", reason: reason}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "team_create_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
