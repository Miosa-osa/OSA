defmodule OptimalSystemAgent.SDK.Permission do
  @moduledoc """
  Permission modes for SDK tool execution.

  5 modes that control what tools are allowed to execute:

  - `:default` — prompts the caller (via on_permission callback) for each tool
  - `:accept_edits` — auto-allow file read/write, prompt for shell/web
  - `:plan` — block all tools, only allow plan mode responses
  - `:bypass` — allow everything (dangerous, for trusted environments)
  - `:deny_all` — block all tool execution

  The SDK injects a permission check as a `:pre_tool_use` hook.
  """

  alias OptimalSystemAgent.SDK.Config

  @type check_result :: :allow | {:block, String.t()} | {:prompt, String.t()}

  @doc """
  Check if a tool call is permitted under the given permission mode.

  Returns `:allow`, `{:block, reason}`, or `{:prompt, description}`.
  """
  @spec check(Config.permission_mode(), String.t(), map()) :: check_result()
  def check(:bypass, _tool_name, _arguments), do: :allow
  def check(:deny_all, tool_name, _arguments), do: {:block, "All tools blocked (deny_all mode). Attempted: #{tool_name}"}
  def check(:plan, tool_name, _arguments), do: {:block, "Plan mode — tools disabled. Attempted: #{tool_name}"}

  def check(:accept_edits, tool_name, _arguments) do
    if tool_name in ~w(file_read file_write memory_save budget_status) do
      :allow
    else
      {:prompt, "Tool '#{tool_name}' requires approval (accept_edits mode)"}
    end
  end

  def check(:default, tool_name, _arguments) do
    {:prompt, "Tool '#{tool_name}' requires approval (default mode)"}
  end

  @doc """
  Build a pre_tool_use hook function for the given permission mode.

  The returned function can be registered with `Agent.Hooks.register/4`.
  When mode is `:bypass`, returns `nil` (no hook needed).
  """
  @spec build_hook(Config.permission_mode()) :: (map() -> {:ok, map()} | {:block, String.t()}) | nil
  def build_hook(:bypass), do: nil

  def build_hook(mode) do
    fn %{tool_name: tool_name, arguments: arguments} = payload ->
      case check(mode, tool_name, arguments) do
        :allow -> {:ok, payload}
        {:block, reason} -> {:block, reason}
        {:prompt, _desc} -> {:ok, payload}
      end
    end
  end
end
