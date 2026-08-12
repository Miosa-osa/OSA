defmodule OptimalSystemAgent.Agent.Context.WorldStateSupersessionTest do
  @moduledoc """
  Append-only supersession — the property that makes strict prefix hold
  STRUCTURALLY.

  codex's `WorldState` never edits an earlier context item; it appends a
  superseding one. That is the whole trick: because history is append-only,
  the prefix cannot be perturbed by an update, so there is no strict-prefix
  invariant to assert and no way to regress it. But it only works if every
  superseding emission SAYS it supersedes — otherwise history holds two
  contradictory copies of the same section and the model has to guess which
  one is current.

  OSA's `:replace` sections already carried that notice. `:plain` sections did
  not: a changed plain section was re-emitted bare, leaving the stale copy
  standing with nothing marking it dead. `:plain` describes the BODY (it stands
  alone, there is nothing to phrase as "instructions replace instructions"), not
  a licence to leave a superseded copy unmarked.

  Every test below asserts on a `:plain` section (`commands` → `:apps`,
  `agent_roles` → `:agent_roles`, `scratchpad` → `:context_guidance`) and fails
  on the pre-change code, where `replace_notice/1` returned `""` for them.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Context.WorldState

  setup do
    session = "ws-supersede-#{System.unique_integer([:positive])}"
    WorldState.reset(session)
    on_exit(fn -> WorldState.reset(session) end)
    {:ok, session: session}
  end

  defp emit(session, blocks) do
    {parts, summary} = WorldState.assemble(session, blocks)
    {WorldState.text(parts), summary}
  end

  test "a changed PLAIN section announces that it supersedes the earlier copy", %{
    session: session
  } do
    {first, _} = emit(session, [{"/plan\n/build", 1, "commands"}])
    assert first =~ "/plan"

    {second, summary} = emit(session, [{"/plan\n/build\n/ship", 1, "commands"}])

    assert summary.changes[:apps] == :changed

    # The stale copy is still sitting in history — append-only means it is never
    # edited away. Without a notice the model sees two catalogs and no ordering.
    assert second =~ "no longer applies",
           "a changed plain section must supersede the copy already in history, " <>
             "not silently duplicate it:\n#{second}"

    assert second =~ "superseded by the following"
    # And the new body still follows the notice.
    assert second =~ "/ship"
  end

  test "the notice names the section, so two changed sections are distinguishable", %{
    session: session
  } do
    emit(session, [{"catalog v1", 1, "commands"}, {"roster v1", 1, "agent_roles"}])

    {second, _} = emit(session, [{"catalog v2", 1, "commands"}, {"roster v2", 1, "agent_roles"}])

    assert second =~ "slash-command catalog no longer applies"
    assert second =~ "subagent roster no longer applies"
  end

  test "an ADDED plain section carries no notice — there is nothing to supersede", %{
    session: session
  } do
    {first, summary} = emit(session, [{"catalog v1", 1, "commands"}])

    assert summary.changes[:apps] == :added

    refute first =~ "no longer applies",
           "a first emission must not claim to supersede anything:\n#{first}"
  end

  test "an UNCHANGED plain section emits nothing at all", %{session: session} do
    {_first, _} = emit(session, [{"catalog v1", 1, "commands"}])
    {_second, summary} = emit(session, [{"catalog v1", 1, "commands"}])

    assert summary.changes[:apps] == :unchanged
    assert summary.emitted == []
  end

  test "the previous payload is replayed BYTE-FOR-BYTE alongside the new one", %{
    session: session
  } do
    {first, _} = emit(session, [{"catalog v1", 1, "commands"}])
    {second, _} = emit(session, [{"catalog v2", 1, "commands"}])

    # Append-only: turn 2's text must literally begin with turn 1's text. This
    # is the strict-prefix property, held structurally rather than asserted at
    # the provider boundary.
    assert String.starts_with?(second, first),
           "the ledger must append, never rewrite — otherwise the cached prefix " <>
             "changes and the whole world-state block re-prefills"
  end

  test "REPLACE sections keep their stronger, instruction-specific wording", %{session: session} do
    emit(session, [{"be terse", 1, "personality"}])
    {second, _} = emit(session, [{"be verbose", 1, "personality"}])

    assert second =~
             "These personality overlay instructions replace all previously provided " <>
               "personality overlay instructions."

    refute second =~ "superseded by the following",
           "the :replace wording must not be weakened to the :plain wording"
  end

  test "a REMOVED plain section still says it went away", %{session: session} do
    emit(session, [{"catalog v1", 1, "commands"}])
    {second, summary} = emit(session, [])

    assert summary.changes[:apps] == :removed

    assert second =~
             "The previously provided slash-command catalog instructions no longer apply."
  end
end
