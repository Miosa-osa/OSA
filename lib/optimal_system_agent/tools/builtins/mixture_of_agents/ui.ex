defmodule OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.UI do
  @moduledoc """
  Render maps for the Rust TUI — `mixture_of_agents`.

  Each `render/3` call returns a structured map the TUI consumes over
  the PubSub event channel. `kind` maps to a TUI component.
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"query" => query} = input, _opts) do
    %{
      kind: "mixture_of_agents",
      query_preview: String.slice(query, 0, 80),
      providers: input["providers"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "mixture_of_agents_result",
      summary: String.slice(content, 0, 120)
    }
  end

  def render(:progress, %{provider: provider, status: status}, _opts) do
    %{
      kind: "mixture_of_agents_progress",
      provider: to_string(provider),
      status: status
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "mixture_of_agents_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "mixture_of_agents_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
