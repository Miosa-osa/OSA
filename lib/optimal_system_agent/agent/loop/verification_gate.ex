defmodule OptimalSystemAgent.Agent.Loop.VerificationGate do
  @moduledoc """
  Grounded verification gate for turn completion.

  Research motivation: **CRITIC** (Gou et al.) and *"Large Language Models
  Cannot Self-Correct Reasoning Yet"* (Huang et al.) both show that
  *ungrounded* self-correction — a model re-judging its own output with no
  external signal — tends to leave accuracy flat or *degrade* it. Reliable
  correction requires **grounding**: an external tool that actually checks the
  claim. This gate enforces that discipline at the point the agent is about to
  declare a turn "done".

  When the agent finishes a turn (the model emitted **no tool calls**) *after*
  having written or edited files this turn, but has **not** run any grounded
  verifying tool (test run / compile / typecheck / lint / re-read) *since the
  last write*, the gate injects a directive requiring a concrete grounded check
  before the agent is allowed to declare completion.

  It is deliberately **conservative**:

    * It only fires when there is a real, un-verified write in the recent
      tool-call window (`recent_tool_names`, the same sliding window
      `DoomLoop` maintains) — never on a read-only or purely conversational
      turn.
    * Re-prompts are capped at #{2} per turn (`@max_reprompts`) so a stubborn
      model can never trap the loop; after the cap the agent is allowed to
      finish and the gate steps aside.

  This complements `Guardrails.needs_verification_gate?/1` (which targets the
  *zero-successful-tools* case) by covering the *wrote-but-never-checked* case.

  ## Usage (wired by the loop)

      if VerificationGate.needs_verification?(state) do
        {directive, state} = VerificationGate.build_directive(state)
        state = %{state | messages: state.messages ++ [directive], ...}
        run(state)
      end

  `build_directive/1` increments the per-turn re-prompt counter it stores in
  `state.verification_gate_prompts` and emits a `:system_event` on the Bus.
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus

  # Cap on how many times the gate may re-prompt within a single turn before
  # stepping aside. Keeps the completion path from looping forever.
  @max_reprompts 2

  # Size of the recent-call window to scan. Mirrors DoomLoop's stall window so
  # both safety mechanisms reason over the same slice of tool history.
  @window_size 6

  # Tools that mutate the workspace (a write or edit). Kept in sync with
  # DoomLoop's notion of forward progress; extra aliases are tolerated.
  @write_edit_tools ~w(file_write file_edit multi_file_edit notebook_edit
                       write_file edit_file apply_patch str_replace
                       str_replace_editor create_file file_append multi_edit)

  # Grounded verifying tools: running something (tests / compile / lint via the
  # shell), or re-reading / re-inspecting the workspace to confirm a claim.
  # These are the *external signals* the research says self-correction needs.
  @verification_tools ~w(shell_execute file_read file_grep file_glob dir_list
                         code_symbols semantic_search codebase_explore repl)

  @doc """
  Returns `true` when the current turn is about to finish with an *unverified*
  write and the re-prompt budget is not yet exhausted.

  A turn is unverified when the most recent write/edit tool in the recent-call
  window is **not** followed by any grounded verifying tool.
  """
  @spec needs_verification?(map()) :: boolean()
  def needs_verification?(state) when is_map(state) do
    reprompts = Map.get(state, :verification_gate_prompts, 0)

    reprompts < @max_reprompts and pending_verification?(recent_tool_window(state))
  end

  def needs_verification?(_), do: false

  @doc """
  Build the grounded-verification directive and advance the per-turn re-prompt
  counter.

  Returns `{directive, updated_state}` where `directive` is a `system` message
  ready to append to `state.messages` and `updated_state` carries the
  incremented `:verification_gate_prompts` counter. Emits a `:system_event` on
  the Bus so the trigger is observable.
  """
  @spec build_directive(map()) :: {map(), map()}
  def build_directive(state) when is_map(state) do
    reprompts = Map.get(state, :verification_gate_prompts, 0)
    step = reprompts + 1
    last_write = last_write_tool(recent_tool_window(state))

    Logger.info(
      "[verification-gate] Unverified write detected (tool: #{last_write || "unknown"}) — " <>
        "injecting grounded-check directive #{step}/#{@max_reprompts} " <>
        "(session: #{Map.get(state, :session_id)})"
    )

    Bus.emit(:system_event, %{
      event: :verification_gate_triggered,
      session_id: Map.get(state, :session_id),
      last_write_tool: last_write,
      reprompt: step,
      max_reprompts: @max_reprompts
    })

    directive = %{
      role: "system",
      content:
        "[VERIFICATION REQUIRED — grounded check #{step}/#{@max_reprompts}] " <>
          "You modified files this turn (last write: `#{last_write || "a file"}`) but have not " <>
          "verified the result with any tool since that change. Ungrounded self-assessment is " <>
          "unreliable — you MUST confirm with a real check before declaring the task done. " <>
          "Run ONE concrete grounded verification now, then report what it actually showed:\n" <>
          "  - Compile / typecheck (e.g. shell_execute `mix compile` or the project's build), or\n" <>
          "  - Run the relevant tests (e.g. shell_execute `mix test <file>`), or\n" <>
          "  - Lint the changed files, or\n" <>
          "  - Re-read the edited file with file_read to confirm the change landed as intended.\n" <>
          "Do NOT claim completion on assertion alone. If a check fails, fix it before finishing."
    }

    {directive, Map.put(state, :verification_gate_prompts, step)}
  end

  # --- Private ---

  # The recent-call window the loop maintains (see DoomLoop.check_stall/2),
  # newest last. Falls back to an empty list on a fresh state.
  @spec recent_tool_window(map()) :: [String.t()]
  defp recent_tool_window(state) do
    state
    |> Map.get(:recent_tool_names, [])
    |> List.wrap()
    |> Enum.take(-@window_size)
  end

  # True when the window contains a write/edit that has no grounded verifying
  # tool after it.
  @spec pending_verification?([String.t()]) :: boolean()
  defp pending_verification?([]), do: false

  defp pending_verification?(window) do
    case last_write_index(window) do
      nil ->
        false

      idx ->
        window
        |> Enum.drop(idx + 1)
        |> Enum.any?(&verification_tool?/1)
        |> Kernel.not()
    end
  end

  @spec last_write_index([String.t()]) :: non_neg_integer() | nil
  defp last_write_index(window) do
    window
    |> Enum.with_index()
    |> Enum.filter(fn {name, _idx} -> write_or_edit_tool?(name) end)
    |> List.last()
    |> case do
      {_name, idx} -> idx
      nil -> nil
    end
  end

  @spec last_write_tool([String.t()]) :: String.t() | nil
  defp last_write_tool(window) do
    case last_write_index(window) do
      nil -> nil
      idx -> Enum.at(window, idx)
    end
  end

  @spec write_or_edit_tool?(String.t()) :: boolean()
  defp write_or_edit_tool?(name) do
    down = name |> to_string() |> String.downcase()

    name in @write_edit_tools or
      String.contains?(down, "write") or
      String.contains?(down, "edit") or
      String.contains?(down, "patch")
  end

  @spec verification_tool?(String.t()) :: boolean()
  defp verification_tool?(name) do
    down = name |> to_string() |> String.downcase()

    name in @verification_tools or
      String.contains?(down, "read") or
      String.contains?(down, "test") or
      String.contains?(down, "grep") or
      String.contains?(down, "shell") or
      String.contains?(down, "exec")
  end
end
