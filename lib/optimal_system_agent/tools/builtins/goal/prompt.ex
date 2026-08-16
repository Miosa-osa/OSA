defmodule OptimalSystemAgent.Tools.Builtins.Goal.Prompt do
  @moduledoc """
  Tool descriptions for `create_goal` and `update_goal`.

  `update_goal/0` is Codex's `create_update_goal_tool/0` description carried
  across almost word for word — it is the part of their goal subsystem that does
  the most work, and paraphrasing it would lose the point.

  `create_goal/0` is Codex's `create_create_goal_tool/0` shape with one
  deliberate substitution: Codex's optional `token_budget` is replaced by
  `acceptance_criteria`, and the criteria-writing rules are grok-build's, from
  `templates/goal_planner_prompt.md`. Codex's goal has no criteria concept at
  all, so there was nothing there to copy for the half of this the user actually
  asked for.
  """

  alias OptimalSystemAgent.Tools.Builtins.Goal.Constants

  @doc """
  Short form, for the advertised tool array (`description/0`).

  `instruction_placement_test.exs` holds total description prose under 45% of
  the encoded tool array, on the rule that policy belongs in the system prompt,
  contracts belong on the parameter, and only what models actually get wrong
  stays in the description. The long form below is not lost by that split — it
  is in `goal_continuation.md`, which is re-injected on every single goal turn
  and is where it does its work. What stays here is the part a model gets wrong
  at CALL time: that the fields freeze, and that a live goal blocks a new one.
  """
  @spec create_goal_short() :: String.t()
  def create_goal_short do
    "Anchor a goal that persists across turns. You author the `objective` and " <>
      "the `acceptance_criteria` yourself; both freeze on creation and no tool " <>
      "can edit them afterwards, so write the honest bar rather than an easy one — " <>
      "a review panel that can see the original request adjudicates completion. " <>
      "Fails while an unfinished goal exists."
  end

  @spec update_goal_short() :: String.t()
  def update_goal_short do
    "Move the active goal to `complete`, `blocked`, or `abandoned` — the only " <>
      "statuses you may set, and the only thing this tool changes. `complete` is a " <>
      "claim, not a verdict: it schedules an independent review panel rather than " <>
      "ending the goal. `blocked` takes effect only after the same blocker has " <>
      "recurred for three consecutive goal turns, and never merely because work is " <>
      "hard, slow, or uncertain. `abandoned` is the exit when the direction changed " <>
      "rather than the difficulty: it ends the goal permanently and on the record, " <>
      "and the next goal inherits the budget already spent."
  end

  @doc """
  Long form, for `prompt/1`.

  Opens with `create_goal_short/0` verbatim. `prompt_assembler_native_dedup_test`
  requires the assembled prose to contain `description/0` as a literal span, so
  that a provider carrying native tool schemas can have the duplicate stripped
  from the system prompt instead of paying for it twice.
  """
  @spec create_goal(keyword()) :: String.t()
  def create_goal(_opts \\ []) do
    update = Constants.update_tool_name()

    create_goal_short() <>
      """


      Create a goal for substantial, multi-turn objectives — the kind that will
      outlive several answers and a context compaction. Do not create one for an
      ordinary single-turn task; that is what simply doing the work is for.

      You author both fields yourself. Write them for three readers who are not
      you: the continuation prompt that will restate them every turn, the
      independent review panel that will judge the finished work against them, and
      yourself after a context reset that has erased everything else.

      `objective` — one concrete sentence naming the end state that must become
      true. Anchor it to what was literally asked. Do not narrow it to the part
      you already know how to do, and do not inflate it with scope nobody
      requested.

      `acceptance_criteria` — the gating set: every one must hold for the goal to
      pass. Keep it SMALL (aim 3-5) and outcome-based, one observable outcome
      each, and say what evidence would prove it. Constrain the WHAT, never the
      HOW: naming the files, functions, or signatures you intend to write pins one
      solution and gets correct work refused for diverging from it. A
      reasonable-but-unrequested feature is not a criterion.

      Both fields are frozen on creation. There is no tool that edits them, and
      `#{update}` changes status only — so the finish line you write now is the
      one you will be held to. A review panel that can see the original request
      adjudicates completion, and criteria that quietly narrow that request are
      themselves grounds to refuse the goal as met. Write the honest bar: an easy
      one does not end the loop sooner, it just fails the audit.

      Fails while an unfinished goal already exists. If your work has genuinely
      moved to a different objective, end the live one first with
      `#{update}` — `blocked` if you are at a real impasse, `abandoned` if it is
      simply no longer the work. The refusal itself names those exits and what
      each costs.
      """
  end

  @doc "Long form, for `prompt/1`. Opens with `update_goal_short/0` — see `create_goal/1`."
  @spec update_goal(keyword()) :: String.t()
  def update_goal(_opts \\ []) do
    update_goal_short() <>
      """


      Use this tool only to mark the goal achieved or genuinely blocked.
      Set status to `complete` only when the objective has actually been achieved and no required work remains.
      Set status to `blocked` only when the same blocking condition has repeated for at least three consecutive goal turns, counting the original/user-triggered turn and any automatic continuations, and you cannot make meaningful progress without user input or an external-state change.
      If the user resumes a goal that was previously marked `blocked`, treat the resumed run as a fresh blocked audit. If the same blocking condition then repeats for at least three consecutive resumed goal turns, set status to `blocked` again.
      Once the blocked threshold is satisfied, do not keep reporting that you are still blocked while leaving the goal active; set status to `blocked`.
      Do not use `blocked` merely because the work is hard, slow, uncertain, incomplete, or would benefit from clarification.
      Do not mark a goal complete merely because you are stopping work.
      Set status to `abandoned` only when the objective itself is no longer the work — the requested direction changed, or the goal rests on a premise that turned out to be false. Never because the objective is hard, slow, uncertain, or looks unwinnable; that is what `blocked` audits and what continuing to work is for. Abandoning ends the goal permanently and records it as abandoned against its objective, and the goal you anchor next inherits the turns and verification rounds this one already spent — so there is no budget to be won by trading a hard objective for an easy one. Say plainly, in your answer to the user, that the goal was abandoned and why.
      You cannot use this tool to pause or resume a goal, or to edit its objective or acceptance criteria; those are controlled by the user.

      `complete` is a claim, not a verdict. It schedules an independent read-only
      review panel, which sees the founding request as well as your objective and
      decides. Claiming completion early does not end the loop — it spends a
      verification round and returns you to work with the panel's objections.
      """
  end
end
