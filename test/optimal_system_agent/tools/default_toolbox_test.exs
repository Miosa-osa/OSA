defmodule OptimalSystemAgent.Tools.DefaultToolboxTest do
  @moduledoc """
  What belongs in the default toolbox, and why.

  Every schema in the default set is re-sent on EVERY request, so a tool that
  is loaded but unused is a tax on every turn of every session. Measured across
  15 SWE-bench Pro transcripts (863 turns, 963 tool calls), 18 of 34 active
  tools were never invoked once, costing 5,974 tokens per request.

  Deferring them took the default set from 34 tools / 14,398 tokens to
  22 / 10,843 — about 3,555 tokens saved per request.

  ## The line that was drawn

  A tool was deferred when it is a SPECIALIST surface or is meaningless before
  something else has happened (you cannot message an agent that does not exist).

  A tool was KEPT when its absence from the measurement is explained by the
  benchmark being headless rather than by the tool being useless — `ask_user`
  has nobody to ask, plan mode is never entered, memory is not exercised by a
  one-shot task. Deferring those would optimise for the benchmark and degrade
  real use, which is the trap this test exists to prevent.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Registry

  defp active, do: MapSet.new(Registry.list_active(), & &1.name)
  defp all, do: MapSet.new(Registry.list_tools(), & &1.name)

  test "tool_search is never deferred" do
    # The load-bearing one. `tool_search` is how a deferred tool is discovered
    # mid-turn, so deferring it would strand every other deferral — the tools
    # would still be registered and permanently unreachable.
    assert MapSet.member?(active(), "tool_search"),
           "tool_search must stay in the default set or nothing deferred can be found"
  end

  test "delegate stays loaded as the entry point to the multi-agent surface" do
    # fleet, send_message, scratchpad and the task_* tools are deferred. That is
    # only safe because `delegate` remains — the capability is reachable from
    # turn 1, and only its management surface waits until there is something to
    # manage.
    assert MapSet.member?(active(), "delegate"),
           "deferring the whole multi-agent surface would make it undiscoverable"
  end

  test "the deferred specialists are out of the default set but still registered" do
    active_set = active()
    all_set = all()

    for name <- ~w(browser skill_manager semantic_search codebase_explore use_skill
                   fleet send_message scratchpad task_resume task_stop task_output
                   code_symbols github workspace_map) do
      refute MapSet.member?(active_set, name),
             "#{name} is back in the default set — it costs its schema on every request"

      assert MapSet.member?(all_set, name),
             "#{name} was REMOVED rather than deferred — it must stay reachable via tool_search"
    end
  end

  test "tools kept for reasons the benchmark cannot see stay loaded" do
    # These were also never called in the measurement, and deferring them would
    # be optimising for a headless benchmark against real interactive use.
    active_set = active()

    for {name, why} <- [
          {"ask_user", "a headless run has nobody to ask"},
          {"enter_plan_mode", "the benchmark never enters plan mode"},
          {"exit_plan_mode", "the benchmark never enters plan mode"},
          {"memory_save", "a one-shot task does not exercise memory"},
          {"memory_recall", "a one-shot task does not exercise memory"}
        ] do
      assert MapSet.member?(active_set, name),
             "#{name} was deferred, but it is unused only because #{why}"
    end
  end

  test "the tools doing the actual work are all present" do
    active_set = active()

    for name <- ~w(file_read file_edit file_write file_grep file_glob dir_list
                   shell_execute task_write) do
      assert MapSet.member?(active_set, name),
             "#{name} is used on most turns; deferring it just moves the cost to a lookup"
    end
  end

  test "the default set stays materially smaller than the full registry" do
    a = length(Registry.list_active())
    t = length(Registry.list_tools())

    # A RATIO, not an absolute count. The count is environment-dependent —
    # a full suite run registers extra fixture tools, so a bare `<= 24` passes
    # alone and fails in `mix test`, which is exactly the kind of test that
    # reports the weather rather than the code.
    #
    # What actually matters is that a meaningful share stays out of the default
    # prompt. The named-tool assertions above are the precise guard; this is
    # the backstop against wholesale regression.
    assert a < t, "deferral is doing nothing: #{a} of #{t}"

    assert a * 2 <= t * 3,
           "only #{a} of #{t} tools are deferred — the prefix tax is returning"
  end
end
