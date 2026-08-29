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
  to bound malformed-args loops; once the cap is EXCEEDED the result turns
  terminal - `{:error, message}` - so the executor surfaces it as a hard
  failed-tool result rather than driving another correction round (P1-7).

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

  Returns `{:ok, tool_call}` to proceed — with `:arguments` replaced by the
  schema-COERCED map (see `Tools.ArgCoercion`), which the caller must be the
  one it executes — or `{:reask, message}` (a correction offer) or, once the
  retry cap is exceeded, `{:error, message}` (terminal). Both error messages
  start with `"Error:"` so downstream finalization treats them as a tool
  failure.
  """
  @spec validate(map(), map()) ::
          {:ok, map()} | {:reask, String.t()} | {:error, String.t()}
  def validate(tool_call, state) do
    session_id = Map.get(state, :session_id)
    tool_name = tool_call.name

    case Registry.module_for(tool_name) do
      nil ->
        # MCP / unknown tool — no local schema to validate against.
        {:ok, tool_call}

      mod ->
        args = Map.get(tool_call, :arguments) || %{}

        case Registry.coerce_and_validate(mod, args) do
          {:ok, coerced} ->
            reset_count(session_id, tool_name)
            # The COERCED arguments are what the caller must execute — a
            # repaired `"30"` that only validates and never runs is no fix at
            # all.
            {:ok, Map.put(tool_call, :arguments, coerced)}

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

    if attempt > @max_reask do
      # Past the correction budget this is no longer a REASK (an offer to try
      # again) - it is a TERMINAL tool failure. Return a plain `{:error, message}`
      # so the executor surfaces it as a hard failed-tool result instead of
      # re-driving the validate/reask cycle (P1-7). The message text is the same
      # `"Error:"`-prefixed body a normal tool error carries, so downstream
      # (`finalize_result` / `FailureSignature`) treats it as a failure.
      #
      # NOTE(turn-hardening): the sole caller, `ToolExecutor.run_tool/2`, matches
      # only `{:reask, _}` and `{:ok, _}` on `validate/2`. It needs an
      # `{:error, message} -> message` clause (mirroring its `{:reask, message} ->
      # message`) so this terminal body reaches the model verbatim; without it a
      # CaseClauseError is caught upstream and the stop-retrying text is lost.
      # That one-line caller change is outside this workstream's file list.
      message =
        "Error: Tool input for `#{tool_name}` is still invalid after #{@max_reask} " <>
          "corrections — #{reason} Stop retrying `#{tool_name}` with the same argument " <>
          "shape; re-read the tool schema or take a different approach."

      {:error, message}
    else
      message =
        "Error: Your tool input for `#{tool_name}` was invalid: #{reason} " <>
          "Rewrite the `#{tool_name}` call with corrected arguments that match the tool " <>
          "schema (correction attempt #{attempt} of #{@max_reask})."

      {:reask, message}
    end
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
