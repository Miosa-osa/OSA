defmodule OptimalSystemAgent.Channels.CLI.Format do
  @moduledoc """
  Shared formatting utilities for the CLI.

  Centralizes token formatting, elapsed time, terminal width queries,
  and model name resolution. Eliminates duplication across spinner,
  renderer, commands, task_display, and agent_tree.
  """

  @doc "Format a token count for display: 0 → \"\", 500 → \"500\", 4200 → \"4.2k\""
  def format_tokens(0), do: ""
  def format_tokens(n) when n < 1_000, do: "#{n}"
  def format_tokens(n), do: "#{Float.round(n / 1_000, 1)}k"

  @doc "Format tokens with arrow prefix for status line: \"↓ 4.2k\""
  def format_tokens_arrow(0), do: ""
  def format_tokens_arrow(n) when n < 1_000, do: "↓ #{n}"
  def format_tokens_arrow(n), do: "↓ #{Float.round(n / 1_000, 1)}k"

  @doc "Format milliseconds as human-readable elapsed time."
  def format_elapsed(ms) when ms < 1_000, do: "<1s"
  def format_elapsed(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  def format_elapsed(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1_000)
    if secs > 0, do: "#{mins}m #{secs}s", else: "#{mins}m"
  end

  @doc "Format duration for tool timing."
  def format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  def format_duration(ms), do: "#{Float.round(ms / 1_000, 1)}s"

  @doc "Get terminal width in columns (default: 80)."
  def terminal_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 80
    end
  end

  @doc "Truncate a string to max length with ellipsis."
  def truncate(str, max) do
    OptimalSystemAgent.Utils.Text.truncate(str, max)
  end

  @doc "Get the current model name for a provider."
  def get_model_name(:anthropic) do
    Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")
  end

  def get_model_name(:ollama) do
    Application.get_env(:optimal_system_agent, :ollama_model, "detecting...")
  end

  def get_model_name(:openai) do
    Application.get_env(:optimal_system_agent, :openai_model, "gpt-4o")
  end

  def get_model_name(provider) do
    key = :"#{provider}_model"
    Application.get_env(:optimal_system_agent, key, to_string(provider))
  end
end
