defmodule OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.UI do
  @moduledoc """
  Render maps for the Rust TUI — `cross_team_query`.

  Each `render/3` call returns a structured map the TUI consumes over
  the PubSub event channel. `kind` maps to a TUI component.
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "cross_team_query",
      action: action,
      target_team: input["target_team"],
      query_id: input["query_id"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "cross_team_query_result",
      summary: String.slice(content, 0, 120)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "cross_team_query_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "cross_team_query_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
