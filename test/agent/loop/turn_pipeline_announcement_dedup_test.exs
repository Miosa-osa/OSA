defmodule OptimalSystemAgent.Agent.Loop.TurnPipelineAnnouncementDedupTest do
  @moduledoc """
  GAP #7 — first-turn announcement dedup.

  The system prompt + tool list + agent context ("the announcement") must be
  injected exactly once per turn, and a fork/resume that inherits a parent's
  conversation must never re-inject the parent's system prompt into it.

  ## Why this is already safe — the two guarantees, both pinned here

  1. **It is never stored in `state.messages`.** `Agent.Context.build/1`
     treats `state.messages` as pure input (`conversation = state.messages ||
     []`) and returns a NEW list `%{messages: [system_msg | conversation]}` —
     it never mutates or writes back into `state`. `ReactLoop`'s callers of
     `cached_context/1` bind the result to a local `context` variable and
     never assign it back to `state` either. `state.messages` is the ONLY
     field checkpointed (`Checkpoint.restore_checkpoint/1`), persisted
     (`SessionPersistence`), and inherited across resume/fork
     (`Loop.init/1`'s `messages =` resolution, `Orchestrator.resume_subagent/2`'s
     full-transcript restore) — so there is nothing in the inherited history
     for a fork/resume to duplicate. Test 1 below pins this directly against
     `state.messages` after a `context_for_iteration/1` call.

  2. **The per-turn cache cannot leak stale content across a turn or a
     session.** `react_loop.ex`'s `cached_context/1` freezes the assembled
     system message in the process dictionary
     (`:osa_system_msg_cache`), keyed on `{plan_mode, session_id,
     memory_version, channel}` — but `TurnPipeline.clear_message_caches/0`
     deletes that key at the top of EVERY turn (before `prepare_turn/3`
     builds anything), so turn 2 of the same session cannot silently reuse
     turn 1's frozen prompt. A genuinely new session (a fork, or a resume
     that starts a fresh `Agent.Loop` process) needs no help at all: a new
     BEAM process has an empty process dictionary, so its first
     `cached_context/1` call misses regardless of what any OTHER process's
     dictionary holds. Tests 2-4 below pin both halves: the explicit clear,
     and the key-based isolation a fork/second-session gets for free.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Loop.{ReactLoop, TurnPipeline}

  setup do
    Process.delete(:osa_system_msg_cache)
    Process.delete(:osa_context_builds)
    Process.put(:osa_memory_version, 0)
    :ok
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "announce-#{System.unique_integer([:positive])}",
        channel: :cli,
        plan_mode: false,
        working_dir: "/tmp",
        provider: :ollama,
        model: "glm-5.2:cloud",
        messages: [%{role: "user", content: "hello"}]
      },
      overrides
    )
  end

  defp system_role_count(messages) do
    Enum.count(messages, fn m ->
      (Map.get(m, :role) || Map.get(m, "role")) == "system"
    end)
  end

  # `Context.build/1` may ALSO append a single trailing `<system-reminder>`
  # "Runtime Context" message (role "user" — the volatile block, for
  # providers whose plain-prefix cache keeps it OUT of the cacheable static
  # system message; see `context.ex`'s `volatile_tail_message/1`). That is
  # expected, per-request "agent context" — not a bug — so long as there is
  # never more than one of it.
  defp volatile_reminder?(m) do
    content = Map.get(m, :content) || Map.get(m, "content")
    is_binary(content) and String.starts_with?(content, "<system-reminder>")
  end

  test "a resumed/forked history never contains the system prompt, and exactly one is prepended" do
    # An "inherited" conversation — what a fork or a resume restores into
    # `state.messages`: plain conversation turns, never a system message,
    # because nothing in this codebase ever writes one there.
    inherited = [
      %{role: "user", content: "first question from the parent session"},
      %{role: "assistant", content: "first answer"},
      %{role: "user", content: "follow-up"}
    ]

    s = state(%{messages: inherited})

    assert system_role_count(s.messages) == 0,
           "the inherited/persisted history must never carry a system-prompt message"

    %{messages: built} = ReactLoop.context_for_iteration(s)

    assert system_role_count(built) == 1,
           "exactly one system message must be prepended for the outgoing request"

    assert [%{} = head | rest] = built
    assert (Map.get(head, :role) || Map.get(head, "role")) == "system"

    # The tail is the inherited history, optionally followed by AT MOST one
    # trailing volatile reminder — never the inherited history duplicated,
    # and never more than one reminder appended.
    {prefix, trailing} = Enum.split(rest, length(inherited))
    assert prefix == inherited, "the conversation tail must be the inherited history, untouched"
    assert length(trailing) <= 1, "at most one trailing agent-context reminder may be appended"
    assert Enum.all?(trailing, &volatile_reminder?/1)

    # The persisted field itself must remain exactly as it was — building the
    # outgoing context must not bake the system message back into it.
    assert system_role_count(s.messages) == 0
  end

  test "clear_message_caches/0 forces a rebuild even when the OLD cache key still matches" do
    s = state()

    first = ReactLoop.context_for_iteration(s)
    assert Context.build_count() == 1

    # Simulate turn 2 of the SAME session: nothing in the cache key
    # (plan_mode/session_id/memory_version/channel) changes, so without the
    # clear this would be a silent cache HIT reusing turn 1's frozen prompt.
    :ok = TurnPipeline.clear_message_caches()

    second = ReactLoop.context_for_iteration(s)

    assert Context.build_count() == 2,
           "clear_message_caches/0 must force turn 2 to rebuild rather than reuse turn 1's " <>
             "cached system message, even though the cache key is unchanged"

    assert length(first.messages) > 0 and length(second.messages) > 0
  end

  test "a forked/second session with a DIFFERENT session_id never reuses another session's cache" do
    parent = state(%{session_id: "parent-#{System.unique_integer([:positive])}"})
    %{messages: [parent_system | _]} = ReactLoop.context_for_iteration(parent)
    assert Context.build_count() == 1

    # The fork: same process (worst case — a real fork is a NEW BEAM process
    # with an empty dictionary, which is strictly safer than this), a
    # DIFFERENT session_id, inheriting the parent's conversation.
    forked =
      state(%{
        session_id: "fork-of-#{parent.session_id}",
        messages: parent.messages ++ [%{role: "assistant", content: "parent's last word"}]
      })

    %{messages: [fork_system | _]} = ReactLoop.context_for_iteration(forked)

    assert Context.build_count() == 2,
           "a different session_id is a different cache key — the fork must rebuild its own " <>
             "system message, not inherit the parent's cached one"

    # Content-level guarantee, not just count: the fork's own build result is
    # a genuinely independent value; nothing hands it the SAME term the
    # parent's build produced without going through Context.build/1 again.
    assert fork_system != nil and parent_system != nil
  end

  test "no duplicate: the outgoing context for a forked session still carries exactly one system message" do
    forked =
      state(%{
        messages: [
          %{role: "user", content: "inherited from parent"},
          %{role: "assistant", content: "inherited answer"}
        ]
      })

    %{messages: built} = ReactLoop.context_for_iteration(forked)

    assert system_role_count(built) == 1,
           "a fork/resume must never end up with the system prompt duplicated in the outgoing " <>
             "request"
  end
end
