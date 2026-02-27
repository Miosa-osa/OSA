defmodule OptimalSystemAgent.SDK.Command do
  @moduledoc """
  SDK wrapper for the slash command system.

  Execute OSA commands programmatically (e.g., `/status`, `/memory`, `/agents`).
  """

  alias OptimalSystemAgent.Commands

  @doc """
  Execute a slash command and return its result.

  ## Examples

      OSA.SDK.Command.execute("/status", "session-123")
      # => {:command, "OSA Agent v3.3 — Status: ..."}

      OSA.SDK.Command.execute("/agents", "session-123")
      # => {:command, "## Agent Roster\\n..."}

  ## Returns
  - `{:command, output}` — command executed, output is the text result
  - `{:prompt, text}` — input was not a command, treat as normal prompt
  - `{:action, action, output}` — command triggered a side-effect action
  - `:unknown` — unrecognized command
  """
  @spec execute(String.t(), String.t()) ::
          {:command, String.t()}
          | {:prompt, String.t()}
          | {:action, atom() | tuple(), String.t()}
          | :unknown
  def execute(input, session_id \\ "sdk") do
    Commands.execute(input, session_id)
  end

  @doc "List all registered commands (built-in + custom)."
  @spec list() :: [map()]
  def list do
    Commands.list_commands()
  end

  @doc "Register a custom slash command at runtime."
  @spec register(String.t(), String.t(), String.t()) :: :ok
  def register(name, description, template) do
    Commands.register(name, description, template)
  end
end
