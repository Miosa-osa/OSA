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

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence
  alias OptimalSystemAgent.Events.Bus

  # Cap on how many times the gate may re-prompt within a single turn before
  # stepping aside. Keeps the completion path from looping forever.
  @max_reprompts 2

  @doc """
  Returns `true` when the current turn is about to finish with an *unverified*
  write and the re-prompt budget is not yet exhausted.

  "Unverified" is now an **evidence** query, not a name heuristic
  (`VerificationEvidence.pending_files/1`): a changed file counts as verified
  only when, *since its last write*, a grounded check **passed (exit 0)** and
  **referenced that file** (or ran a project build/test). An unrelated
  `file_read` or a non-zero `shell_execute` no longer satisfies the gate.
  """
  # A FAILING check is also a reason to continue, not only a missing one.
  #
  # This gate asked one question — "was the edit ever checked" — and a failing
  # check answered it in the affirmative, because the ledger recorded that a
  # check happened. `tool_executor` stores `success: false` for a red test and
  # the loop then discarded it. Two independent studies of our own transcripts
  # found the same thing: every harness examined gates on the ABSENCE of
  # verification and none on the PRESENCE of a failure.
  #
  # The two signals are different questions and both matter:
  #   pending_files/1               -> "this edit was never checked"
  #   failing_check_since_write/1   -> "this edit was checked and it failed"
  @spec needs_verification?(map()) :: boolean()
  def needs_verification?(state) when is_map(state) do
    reprompts = Map.get(state, :verification_gate_prompts, 0)
    session_id = Map.get(state, :session_id)

    reprompts < @max_reprompts and session_id != nil and
      (VerificationEvidence.pending_files(session_id) != [] or
         VerificationEvidence.failing_check_since_write(session_id) != nil)
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
    session_id = Map.get(state, :session_id)
    last_write = session_id && VerificationEvidence.last_write_tool(session_id)
    pending = (session_id && VerificationEvidence.pending_files(session_id)) || []

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

    files_note =
      case pending do
        [] -> "the file(s) you changed"
        [one] -> "`#{one}`"
        many -> Enum.map_join(many, ", ", &"`#{&1}`")
      end

    directive = %{
      # `user`, not `system` — this directive is appended after assistant TEXT,
      # and Anthropic/Gemini reject a system message in that position with a
      # 400. That made the verification gate a no-op on those families: it
      # never ran once. See react_loop's handle_result for the full note.
      role: "user",
      content:
        "[VERIFICATION REQUIRED — grounded check #{step}/#{@max_reprompts}] " <>
          "You modified #{files_note} this turn (last write: `#{last_write || "a file"}`) but no " <>
          "grounded check has PASSED (exit 0) against #{if pending == [], do: "them", else: "that file(s)"} " <>
          "since the change. Ungrounded self-assessment is unreliable, and an unrelated read or a " <>
          "failed command does NOT count — you MUST confirm with a real, passing check that touches " <>
          "the changed file(s) before declaring the task done. Run ONE now, then report what it showed:\n" <>
          "  - Compile / typecheck (e.g. shell_execute `mix compile` or the project's build), or\n" <>
          "  - Run the relevant tests (e.g. shell_execute `mix test <file>`), or\n" <>
          "  - Lint the changed files, or\n" <>
          "  - Re-read the edited file with file_read to confirm the change landed as intended.\n" <>
          "Do NOT claim completion on assertion alone. If a check fails, fix it before finishing."
    }

    {directive, Map.put(state, :verification_gate_prompts, step)}
  end
end
