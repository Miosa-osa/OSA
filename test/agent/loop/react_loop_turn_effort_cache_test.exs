defmodule OptimalSystemAgent.Agent.Loop.ReactLoopTurnEffortCacheTest do
  @moduledoc """
  The cache-safety half of per-turn effort shaping (item 17).

  `with_turn_effort/2` floors a tool-loop continuation down to `:fast` so
  digesting a tool result and firing the next call stays snappy — a real,
  deliberate, already-shipped feature (see `ReactLoopTurnEffortTest`). The bug
  this covers is narrower: `ToolFilter.filter/2` (via `FastPath.select_tools/2`
  and `Effort.tool_budget/0`) reads `Effort.current()`, and tool definitions
  sit at the front of the CACHED prefix on every provider that honours
  `cache_control`. Resolving the tool list INSIDE the turn-scoped override
  meant a continuation changed WHICH TOOLS were sent, on every single
  continuation — busting the tools-array cache breakpoint on every one of
  them, not just at genuine content changes.

  These tests drive a REAL `ReactLoop.run/1` call through `MockProvider` and
  assert on the ACTUAL wire-shaped tool array (`MockProvider.last_opts()[:tools]`),
  not on a claim about which line of code resolves it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  # A message that classifies to the `:code` intent (`fix` + `code`), so
  # `FastPath.select_tools/2` under `:fast` returns a REDUCED, INTENT-MATCHED
  # subset rather than the tool list unchanged — the exact shape of the
  # cache-busting bug this covers. Deliberately padded with several tools
  # OUTSIDE that intent's set (`computer_use`, `memory_recall`, `cron`,
  # `notebook_edit`) so a fast-mode reduction is visibly different in SIZE,
  # not just in some cosmetic reordering.
  defp trigger_message, do: "please fix the code"

  defp rich_tool_list do
    ~w(
      tool_search skill_view delegate orchestrate ask_user task_write file_read
      shell_execute file_write file_edit multi_file_edit structural_edit git
      grep diff computer_use memory_recall memory_save cron notebook_edit
      browser launch_app
    )
    |> Enum.map(&%{name: &1, description: &1, parameters: %{"type" => "object"}})
  end

  setup do
    saved =
      for key <- [:default_provider, :max_iterations, :effort_level, :mock_provider_final_text],
          into: %{},
          do: {key, Application.fetch_env(:optimal_system_agent, key)}

    prev_env = System.get_env("OSA_DEFAULT_PROVIDER")
    System.put_env("OSA_DEFAULT_PROVIDER", "mock")
    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    # Comfortably above the highest iteration either call in these tests
    # starts at — a run whose starting iteration already meets the cap takes
    # `forced_wrapup` (tools: [], no normal do_iteration), which would make
    # the comparison below vacuous rather than a test of the fix.
    Application.put_env(:optimal_system_agent, :max_iterations, 5)
    Application.put_env(:optimal_system_agent, :mock_provider_final_text, "done")
    Effort.set(:medium)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, v}} -> Application.put_env(:optimal_system_agent, key, v)
        {key, :error} -> Application.delete_env(:optimal_system_agent, key)
      end)

      case prev_env do
        nil -> System.delete_env("OSA_DEFAULT_PROVIDER")
        v -> System.put_env("OSA_DEFAULT_PROVIDER", v)
      end
    end)

    :ok
  end

  defp sid, do: "turn-effort-cache-#{System.unique_integer([:positive])}"

  defp base_state(session_id, iteration) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: session_id,
      provider: :mock,
      model: "mock-model-1.0",
      iteration: iteration,
      auto_continues: 0,
      messages: [%{role: "user", content: trigger_message()}],
      tools: rich_tool_list(),
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  defp tool_names(opts) do
    opts
    |> Keyword.get(:tools, [])
    |> Enum.map(&(Map.get(&1, :name) || Map.get(&1, "name")))
    |> Enum.sort()
  end

  test "the wire tool list at a tool-loop continuation matches the first response's" do
    session_id = sid()

    MockProvider.reset_last_opts()
    {_response, _state} = ReactLoop.run(base_state(session_id, 0))
    iter0_tools = tool_names(MockProvider.last_opts())

    MockProvider.reset_last_opts()
    {_response, _state} = ReactLoop.run(base_state(session_id, 1))
    iter1_tools = tool_names(MockProvider.last_opts())

    assert iter0_tools != [],
           "sanity: the mock call must actually have carried a tool list"

    assert iter0_tools == iter1_tools,
           "a tool-loop continuation must send the IDENTICAL tool array as the " <>
             "turn's first response — sending a different one busts the " <>
             "cache_control breakpoint on the tools array every single " <>
             "continuation.\niter0: #{inspect(iter0_tools)}\niter1: #{inspect(iter1_tools)}"
  end

  test "sanity: iteration 1 really does classify as a :fast continuation at :medium" do
    # If this stopped being true, the test above would pass for the wrong
    # reason — there would be nothing left to bust the cache with. Covered
    # exhaustively by `ReactLoopTurnEffortTest`; repeated here as the
    # precondition this file's claim depends on.
    Effort.set(:medium)
    assert ReactLoop.turn_effort(%{iteration: 1}) == :fast
    assert ReactLoop.turn_effort(%{iteration: 0}) == nil

    refute Effort.fast_mode?()
    Effort.with_process_override(:fast, fn -> assert Effort.fast_mode?() end)
    refute Effort.fast_mode?()
  end
end
