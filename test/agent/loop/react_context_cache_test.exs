defmodule OptimalSystemAgent.Agent.Loop.ReactContextCacheTest do
  @moduledoc """
  The ReAct loop's per-turn system-prompt cache reported hits while doing the
  full work of a miss.

  `cached_context/1` keys on `{plan_mode, session_id, memory_version, channel}`
  and freezes the assembled system message for the duration of one
  `process_message` call, so iterations 1..N of a ReAct turn reuse iteration 0's
  prompt. But the hit branch opened with `full = Context.build(state)` and then
  discarded the system message it had just built, substituting the cached one:

      {^cache_key, cached} ->
        full = Context.build(state)
        %{full | messages: [cached | rest]}

  `Context.build/1` resolves the context window, selects and fetches the static
  base, and assembles twenty-one dynamic blocks against a token budget. All of
  that ran on every iteration of every turn, and its only surviving output was
  `rest` — the conversation tail, which is `state.messages` unchanged.

  A cache that never saves anything is worse than no cache: it makes the cost
  invisible. `Context.build_count/0` is the counter that makes it visible.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Loop.ReactLoop

  setup do
    Process.delete(:osa_system_msg_cache)
    Process.delete(:osa_context_builds)
    Process.put(:osa_memory_version, 0)
    :ok
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "react-cache-#{:erlang.unique_integer([:positive])}",
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

  test "the first iteration builds; every later one does not" do
    s = state()

    assert Context.build_count() == 0
    first = ReactLoop.context_for_iteration(s)
    assert Context.build_count() == 1, "iteration 0 must assemble the prompt"

    for _ <- 1..5 do
      ReactLoop.context_for_iteration(s)
    end

    assert Context.build_count() == 1,
           "five cache HITS triggered #{Context.build_count() - 1} extra full " <>
             "Context.build/1 calls — the cache is paying for what it claims to skip"

    refute first.messages == []
  end

  test "a hit returns the frozen system message in front of the live conversation" do
    s = state()
    %{messages: [system | _]} = ReactLoop.context_for_iteration(s)

    # A later iteration has appended tool results to the history.
    grown =
      Map.put(s, :messages, s.messages ++ [%{role: "assistant", content: "using a tool"}])

    %{messages: [system2 | rest]} = ReactLoop.context_for_iteration(grown)

    assert system2 == system, "the prompt is frozen for the turn — that is the point"

    assert rest == grown.messages,
           "the conversation must be the LIVE history, not a stale copy"
  end

  test "a key change invalidates and rebuilds exactly once" do
    s = state()
    ReactLoop.context_for_iteration(s)
    assert Context.build_count() == 1

    # plan_mode is part of the key: entering plan mode must not reuse the
    # normal-mode prompt.
    planning = Map.put(s, :plan_mode, true)
    ReactLoop.context_for_iteration(planning)
    assert Context.build_count() == 2

    ReactLoop.context_for_iteration(planning)
    assert Context.build_count() == 2, "the new key must itself be cached"
  end

  test "the memory version is part of the key, so a save invalidates the prompt" do
    s = state()
    ReactLoop.context_for_iteration(s)
    assert Context.build_count() == 1

    Process.put(:osa_memory_version, 1)
    ReactLoop.context_for_iteration(s)

    assert Context.build_count() == 2,
           "a memory write must be reflected in the next iteration's prompt"
  end
end
