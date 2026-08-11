defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.UI do
  @moduledoc """
  Render maps for the Rust TUI — computer_use edition.

  No Rust renderer exists yet for computer_use, so this module emits
  structured payloads that a future renderer can consume without breaking
  changes. The `kind` values are the stable contract:

    * `"computer_use"`            — model issued an action (tool_use stage)
    * `"computer_use_screenshot"` — screenshot result with image metadata
    * `"computer_use_action"`     — non-screenshot action result (click, type, …)
    * `"computer_use_rejected"`   — permission denied
    * `"computer_use_error"`      — execution error

  Rendered maps are delivered over the existing PubSub event channel used
  by `file_read` and other structured tools. The Rust side maps `kind` to
  a component once the renderer is implemented.
  """

  alias OptimalSystemAgent.Security.TypedText

  @spec render(atom(), any(), keyword()) :: map() | nil

  # ── :tool_use — model is about to call the tool ───────────────────────

  def render(:tool_use, %{"action" => action} = input, _opts) do
    %{
      kind: "computer_use",
      action: action,
      x: input["x"],
      y: input["y"],
      # `text` on a typing action is the user's keystrokes — a password when the
      # model is filling a login form. The render map is broadcast over PubSub
      # and drawn in the TUI, so it carries the shape, not the value.
      text: TypedText.mask_for_action(action, input["text"]),
      target: input["target"],
      direction: input["direction"],
      region: input["region"],
      window: input["window"]
    }
  end

  # ── :tool_result — screenshot ─────────────────────────────────────────

  def render(:tool_result, {:image, %{path: path} = meta}, _opts) do
    %{
      kind: "computer_use_screenshot",
      path: path,
      media_type: Map.get(meta, :media_type, "image/png")
    }
  end

  # ── :tool_result — non-screenshot action ─────────────────────────────

  def render(:tool_result, result, _opts) when is_binary(result) do
    %{
      kind: "computer_use_action",
      result: result
    }
  end

  def render(:tool_result, :ok, _opts) do
    %{kind: "computer_use_action", result: "ok"}
  end

  def render(:tool_result, result, _opts) do
    %{kind: "computer_use_action", result: inspect(result)}
  end

  # ── :rejected — permission denied ────────────────────────────────────

  def render(:rejected, _input, _opts) do
    %{kind: "computer_use_rejected"}
  end

  # ── :error ────────────────────────────────────────────────────────────

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "computer_use_error", message: msg}
  end

  def render(:error, reason, _opts) do
    %{kind: "computer_use_error", message: inspect(reason)}
  end

  # ── :progress — future streaming support ─────────────────────────────

  def render(:progress, %{step: step, total: total} = payload, _opts) do
    %{
      kind: "computer_use_progress",
      step: step,
      total: total,
      action: Map.get(payload, :action)
    }
  end

  def render(_stage, _payload, _opts), do: nil
end
