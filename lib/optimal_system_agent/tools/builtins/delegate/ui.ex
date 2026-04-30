defmodule OptimalSystemAgent.Tools.Builtins.Delegate.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Elixir-side counterpart to the `DelegateRenderer` in
  `priv/rust/tui/src/tools/agent.rs`. The Rust renderer reads:

    * `:tool_use`    — from `args` JSON: `task`, `tier`, `role`, `background`, `fork`
    * `:tool_result` — the raw result string; first line shown in collapsed mode

  The maps returned here flow through the PubSub event channel to the TUI.
  The `kind` key must stay `"delegate"` / `"delegate_result"` / etc. because
  the Rust dispatcher matches on the tool name string directly from args — the
  `DelegateRenderer` does its own JSON parsing of args. We still emit structured
  maps for the Elixir-side consumers (telemetry, logging, hook system).

  ## Frontend contract (DelegateRenderer)
    * `args` → parses `["task", "description", "input", "prompt"]` for task display
    * `args` → parses `["tier", "model_tier", "agent_tier"]` for tier badge
    * `result` → first line shown collapsed, full body shown expanded
  """

  @spec render(atom(), any(), keyword()) :: map() | nil

  def render(:tool_use, %{"task" => task} = input, _opts) do
    %{
      kind: "delegate",
      task: task,
      role: input["role"],
      tier: input["tier"],
      background: input["background"] == true,
      fork: input["fork"] == true
    }
  end

  def render(:tool_result, result, _opts) when is_binary(result) do
    first_line =
      result
      |> String.split("\n", parts: 2)
      |> List.first("")
      |> String.trim()

    %{
      kind: "delegate_result",
      summary: first_line,
      bytes: byte_size(result)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "delegate_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "delegate_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
