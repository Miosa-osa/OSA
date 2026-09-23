defmodule OptimalSystemAgent.Providers.ToolCallDedup do
  @moduledoc """
  Stream-parse-layer dedup for tool_use/tool_call events, keyed by id.

  ## Why this exists

  `providers/ollama.ex` and `providers/anthropic.ex` both accumulate streamed
  tool calls into a list as chunks/events arrive (`acc.tool_calls ++ new` on
  Ollama, `[tool_call | acc.tool_calls]` on Anthropic), with no check for
  whether a call with the same id had already been added. A provider that
  re-delivers the same completed tool_use block — a re-sent cumulative chunk,
  a retried mid-stream fragment, a malformed reconnect — therefore produced
  TWO entries for one call. Downstream, `Agent.Loop.ToolOrchestrator.uniquify_ids/1`
  is the final repair for a duplicate id, but it RENAMES the second occurrence
  so both are treated as distinct calls and BOTH EXECUTE — the correct
  behaviour for a genuine id collision between two different calls, and the
  wrong one for the exact same call reported twice, which then runs its tool
  (`file_write`, `shell_execute`, ...) a second time.

  This module is the fix at its root: dedup BEFORE the list ever reaches
  `uniquify_ids/1`, so an exact repeat never gets there in the first place. A
  same-id call whose name or arguments actually differ is left alone — that is
  a genuine conflict, not a duplicate, and `uniquify_ids/1` still owns
  resolving it (per-id rename) exactly as before.

  See `Agent.Loop.StreamingToolExecutor.tool_block_complete/3` for the second
  half of this fix: a defensive check so even a duplicate that slips past this
  layer cannot start the same tool_use id twice.
  """

  require Logger

  @type tool_call :: %{id: term(), name: String.t(), arguments: map()}
  @type verdict :: :new | :exact_duplicate | :conflict

  @doc """
  Classify `new_call` against `existing` (a list of tool calls already
  accumulated this turn), by id:

    * `:new`             — no prior call carries this id.
    * `:exact_duplicate`  — a prior call has the same id, name AND arguments.
    * `:conflict`         — a prior call has the same id but different name
      and/or arguments (two different calls racing to reuse one id).

  A missing/`nil` id never matches — it is always `:new` (nothing to compare
  it against, and minting a fresh id for it is `ToolOrchestrator`'s job, not
  this module's).
  """
  @spec classify(list(tool_call()), tool_call()) :: verdict()
  def classify(existing, new_call) when is_list(existing) and is_map(new_call) do
    id = Map.get(new_call, :id)

    case id && Enum.find(existing, fn tc -> Map.get(tc, :id) == id end) do
      nil ->
        :new

      prior ->
        if Map.get(prior, :name) == Map.get(new_call, :name) and
             Map.get(prior, :arguments) == Map.get(new_call, :arguments) do
          :exact_duplicate
        else
          :conflict
        end
    end
  end

  @doc """
  Append `new_call` to `existing` (provider order preserved), unless it is an
  EXACT duplicate of a call already present — same `:id`, `:name` and
  `:arguments`. An exact duplicate is dropped silently (logged at info).

  A call that reuses an id already in `existing` but with a DIFFERENT `:name`
  or `:arguments` is a genuine conflict: it is appended as-is (so
  `ToolOrchestrator.uniquify_ids/1` can still repair the id downstream) and
  logged loudly, because two tool calls racing to reuse one id is not a
  condition anything should stay quiet about.
  """
  @spec append(list(tool_call()), tool_call()) :: list(tool_call())
  def append(existing, new_call) when is_list(existing) and is_map(new_call) do
    case classify(existing, new_call) do
      :new ->
        existing ++ [new_call]

      :exact_duplicate ->
        Logger.info(
          "[tool_call_dedup] dropped exact duplicate tool_use id=#{inspect(Map.get(new_call, :id))} " <>
            "name=#{inspect(Map.get(new_call, :name))} — already streamed this turn"
        )

        existing

      :conflict ->
        Logger.warning(
          "[tool_call_dedup] tool_use id=#{inspect(Map.get(new_call, :id))} reused with " <>
            "DIFFERENT name/arguments — keeping both for id repair " <>
            "(ToolOrchestrator.uniquify_ids/1)"
        )

        existing ++ [new_call]
    end
  end

  @doc """
  Append every call in `new_calls` (in order) to `existing`, via `append/2`.
  """
  @spec append_all(list(tool_call()), list(tool_call())) :: list(tool_call())
  def append_all(existing, new_calls) when is_list(existing) and is_list(new_calls) do
    Enum.reduce(new_calls, existing, &append(&2, &1))
  end

  @doc """
  Prepend `new_call` to `existing` unless it is an exact duplicate (same rules
  as `append/2`), for accumulators that build the list newest-first (Anthropic
  prepends as each `content_block_stop` completes a tool block). Returns the
  updated newest-first list; a dropped duplicate returns `existing` unchanged.
  """
  @spec prepend(list(tool_call()), tool_call()) :: list(tool_call())
  def prepend(existing, new_call) when is_list(existing) and is_map(new_call) do
    existing
    |> Enum.reverse()
    |> append(new_call)
    |> Enum.reverse()
  end
end
