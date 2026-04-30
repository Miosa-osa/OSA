defmodule OptimalSystemAgent.Tools.Builtins.AskUser.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Each `render/3` call returns a structured map consumed by the TUI over
  the PubSub event channel. The TUI maps `kind` to a component — for
  `ask_user` this triggers the SurveyDialog popup.

  Stages:
    * `:tool_use`    — model called the tool; TUI opens survey dialog
    * `:tool_result` — answer received; TUI collapses the dialog
    * `:error`       — execution error (e.g. timeout)
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"question" => question} = input, _opts) do
    %{
      kind: "ask_user",
      question: question,
      options: input["options"] || []
    }
  end

  def render(:tool_result, answer, _opts) when is_binary(answer) do
    %{
      kind: "ask_user_result",
      answer: answer
    }
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "ask_user_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
