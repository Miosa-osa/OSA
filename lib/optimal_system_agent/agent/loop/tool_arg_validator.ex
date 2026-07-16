defmodule OptimalSystemAgent.Agent.Loop.ToolArgValidator do
  @moduledoc """
  Schema-validates tool-call arguments at the agent-loop execution boundary and
  produces an Instructor-style REASK when the model emits malformed / invalid
  input — instead of silently running the tool with empty (`%{}`) arguments
  (BUG A / primitive #31).

  This is the single validation chokepoint for every tool, mirroring OpenCode's
  centralised `wrap()`: it is called once from `ToolExecutor.run_tool/2`, before
  the pre_tool_use hooks and dispatch, so no tool can run with arguments that do
  not conform to its published JSON Schema (`parameters/0`).

  On invalid arguments it returns `{:reask, message}`. The message is a
  model-facing error the loop feeds back verbatim as the tool result, so the
  model rewrites the call on its next step. Retries are capped at `@max_reask`
  per `{session_id, tool_name}` (tracked in the `:osa_reask_counts` ETS table)
  to bound malformed-args loops; after the cap the message becomes terminal.

  MCP tools and unknown/aliased names have no local schema and are passed
  through untouched (`:ok`) — MCP servers validate their own inputs.
  """

  require Logger

  alias OptimalSystemAgent.Tools.Registry

  # Number of REASK corrections offered before the message turns terminal.
  @max_reask 2
  @table :osa_reask_counts

  @doc """
  Validate `tool_call.arguments` against the tool's schema.

  Returns `:ok` to proceed, or `{:reask, message}` where `message` starts with
  `"Error:"` so downstream finalization treats it as a tool failure.
  """
  @spec validate(map(), map()) :: :ok | {:reask, String.t()}
  def validate(tool_call, state) do
    session_id = Map.get(state, :session_id)
    tool_name = tool_call.name

    case Registry.module_for(tool_name) do
      nil ->
        # MCP / unknown / aliased tool — no local schema to validate against.
        :ok

      mod ->
        args = Map.get(tool_call, :arguments) || %{}

        case Registry.validate_arguments(mod, args) do
          :ok ->
            reset_count(session_id, tool_name)
            :ok

          {:error, reason} ->
            reask(session_id, tool_name, reason)
        end
    end
  end

  # --- Private ---

  defp reask(session_id, tool_name, reason) do
    attempt = bump_count(session_id, tool_name)

    Logger.warning(
      "[loop] REASK #{tool_name} (attempt #{attempt}/#{@max_reask}) — invalid arguments: #{reason}"
    )

    message =
      if attempt > @max_reask do
        "Error: Tool input for `#{tool_name}` is still invalid after #{@max_reask} " <>
          "corrections — #{reason} Stop retrying `#{tool_name}` with the same argument " <>
          "shape; re-read the tool schema or take a different approach."
      else
        "Error: Your tool input for `#{tool_name}` was invalid: #{reason} " <>
          "Rewrite the `#{tool_name}` call with corrected arguments that match the tool " <>
          "schema (correction attempt #{attempt} of #{@max_reask})."
      end

    {:reask, message}
  end

  # Atomically increment and return the invalid-attempt counter for this
  # {session, tool}. Falls back to 1 (first attempt) if the ETS table is absent
  # — the REASK still fires, only the cap tracking is skipped.
  defp bump_count(session_id, tool_name) do
    key = {session_id, tool_name}

    try do
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
    rescue
      ArgumentError -> 1
    end
  end

  # Clear the counter once the tool validates cleanly so a later, unrelated
  # malformed call starts its retry budget fresh.
  defp reset_count(session_id, tool_name) do
    try do
      :ets.delete(@table, {session_id, tool_name})
    rescue
      ArgumentError -> true
    end

    :ok
  end
end
