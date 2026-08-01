defmodule OptimalSystemAgent.Agent.Tasks.TrackerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Agent.Tasks.Tracker

  # ── Helpers ──────────────────────────────────────────────────────

  defp start_tracker do
    name = :"tracker_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Tasks.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {pid, name}
  end

  defp session_id do
    id = "test_tracker_#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      base = System.get_env("OSA_HOME") || Path.expand("~/.osa")
      dir = Path.join([base, "sessions", id])
      File.rm_rf(dir)
    end)

    id
  end

  # ── add_task ────────────────────────────────────────────────────

  describe "add_task/3" do
    test "returns ok with task id" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:ok, id} = Tasks.add_task(sid, "Do something", name)
      assert is_binary(id)
      assert String.length(id) == 8
    end

    test "task starts as pending" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, _id} = Tasks.add_task(sid, "My task", name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :pending
      assert task.title == "My task"
      assert task.tokens_used == 0
    end

    test "multiple adds accumulate in order" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, _} = Tasks.add_task(sid, "First", name)
      {:ok, _} = Tasks.add_task(sid, "Second", name)
      {:ok, _} = Tasks.add_task(sid, "Third", name)
      tasks = Tasks.get_tasks(sid, name)
      assert length(tasks) == 3
      assert Enum.map(tasks, & &1.title) == ["First", "Second", "Third"]
    end
  end

  # ── add_tasks (bulk) ───────────────────────────────────────────

  describe "add_tasks/3" do
    test "adds multiple tasks at once" do
      {_pid, name} = start_tracker()
      sid = session_id()
      titles = ["Task A", "Task B", "Task C"]
      assert {:ok, ids} = Tasks.add_tasks(sid, titles, name)
      assert length(ids) == 3
      tasks = Tasks.get_tasks(sid, name)
      assert Enum.map(tasks, & &1.title) == titles
    end

    test "empty list returns empty ids" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:ok, []} = Tasks.add_tasks(sid, [], name)
      assert Tasks.get_tasks(sid, name) == []
    end
  end

  # ── start_task ─────────────────────────────────────────────────

  describe "start_task/3" do
    test "transitions to in_progress" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Work item", name)
      assert :ok = Tasks.start_task(sid, id, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :in_progress
      assert task.started_at != nil
    end

    test "returns error for unknown task" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:error, :not_found} = Tasks.start_task(sid, "nonexistent", name)
    end
  end

  # ── complete_task ──────────────────────────────────────────────

  describe "complete_task/3" do
    test "transitions to completed" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Finish me", name)
      Tasks.start_task(sid, id, name)
      assert :ok = Tasks.complete_task(sid, id, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :completed
      assert task.completed_at != nil
    end

    test "can complete without starting first" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Skip ahead", name)
      assert :ok = Tasks.complete_task(sid, id, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :completed
    end

    test "returns error for unknown task" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:error, :not_found} = Tasks.complete_task(sid, "bad_id", name)
    end
  end

  # ── fail_task ──────────────────────────────────────────────────

  describe "fail_task/4" do
    test "transitions to failed with reason" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Will fail", name)
      Tasks.start_task(sid, id, name)
      assert :ok = Tasks.fail_task(sid, id, "timeout", name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :failed
      assert task.reason == "timeout"
      assert task.completed_at != nil
    end

    test "returns error for unknown task" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:error, :not_found} = Tasks.fail_task(sid, "nope", "err", name)
    end
  end

  # ── get_tasks ──────────────────────────────────────────────────

  describe "get_tasks/2" do
    test "returns empty list for unknown session" do
      {_pid, name} = start_tracker()
      assert Tasks.get_tasks("no_such_session", name) == []
    end

    test "returns tasks in insertion order" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, _} = Tasks.add_task(sid, "A", name)
      {:ok, _} = Tasks.add_task(sid, "B", name)
      tasks = Tasks.get_tasks(sid, name)
      assert [%{title: "A"}, %{title: "B"}] = tasks
    end
  end

  # ── clear_tasks ────────────────────────────────────────────────

  describe "clear_tasks/2" do
    test "removes all tasks for a session" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, _} = Tasks.add_task(sid, "Remove me", name)
      assert :ok = Tasks.clear_tasks(sid, name)
      assert Tasks.get_tasks(sid, name) == []
    end

    test "does not affect other sessions" do
      {_pid, name} = start_tracker()
      sid1 = session_id()
      sid2 = session_id()
      {:ok, _} = Tasks.add_task(sid1, "S1 task", name)
      {:ok, _} = Tasks.add_task(sid2, "S2 task", name)
      Tasks.clear_tasks(sid1, name)
      assert Tasks.get_tasks(sid1, name) == []
      assert length(Tasks.get_tasks(sid2, name)) == 1
    end
  end

  # ── record_tokens ──────────────────────────────────────────────

  describe "record_tokens/4" do
    test "accumulates token count" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Token task", name)
      Tasks.record_tokens(sid, id, 500, name)
      _ = Tasks.get_tasks(sid, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.tokens_used == 500

      Tasks.record_tokens(sid, id, 300, name)
      _ = Tasks.get_tasks(sid, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.tokens_used == 800
    end
  end

  # ── extract_tasks_from_response ────────────────────────────────

  describe "extract_tasks_from_response/1" do
    test "parses numbered list" do
      text = """
      Here's the plan:
      1. Explore the codebase structure
      2. Identify authentication patterns
      3. Design the API schema
      4. Implement user endpoints
      5. Write integration tests
      """

      titles = Tasks.extract_tasks_from_response(text)
      assert length(titles) == 5
      assert "Explore the codebase structure" in titles
      assert "Write integration tests" in titles
    end

    test "parses markdown checkboxes" do
      text = """
      - [ ] Set up the database schema
      - [ ] Create migration files
      - [x] Review requirements
      - [ ] Write the controller
      """

      titles = Tasks.extract_tasks_from_response(text)
      assert length(titles) == 4
      assert "Set up the database schema" in titles
      assert "Review requirements" in titles
    end

    test "filters titles outside 5-120 chars" do
      text = """
      1. Hi
      2. This is a valid task title
      3. #{String.duplicate("x", 121)}
      """

      titles = Tasks.extract_tasks_from_response(text)
      assert length(titles) == 1
      assert "This is a valid task title" in titles
    end

    test "caps at 20 tasks" do
      lines = Enum.map_join(1..25, "\n", fn i -> "#{i}. Task number #{i} here" end)
      titles = Tasks.extract_tasks_from_response(lines)
      assert length(titles) == 20
    end

    test "deduplicates titles" do
      text = """
      1. Same task repeated
      2. Same task repeated
      3. A different task here
      """

      titles = Tasks.extract_tasks_from_response(text)
      assert length(titles) == 2
    end

    test "returns empty for non-list text" do
      assert Tasks.extract_tasks_from_response("Just a paragraph of text.") == []
    end

    test "returns empty for nil" do
      assert Tasks.extract_tasks_from_response(nil) == []
    end
  end

  # ── Persistence roundtrip ──────────────────────────────────────

  describe "persistence" do
    test "tasks survive restart" do
      sid = session_id()
      name1 = :"tracker_persist_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Tasks.start_link(name: name1)
      {:ok, _id} = Tasks.add_task(sid, "Persistent task", name1)
      GenServer.stop(pid1)

      name2 = :"tracker_persist_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Tasks.start_link(name: name2)

      on_exit(fn ->
        if Process.alive?(pid2), do: GenServer.stop(pid2)
        base = System.get_env("OSA_HOME") || Path.expand("~/.osa")
        path = Path.join([base, "sessions", sid, "tasks.json"])
        File.rm(path)
      end)

      tasks = Tasks.get_tasks(sid, name2)
      assert length(tasks) == 1
      assert hd(tasks).title == "Persistent task"
    end
  end

  # ── extract_from_response (direct module) ─────────────────────

  describe "Tracker.extract_from_response/1" do
    test "delegates correctly" do
      text = "1. First task here\n2. Second task here\n3. Third task here"
      assert length(Tracker.extract_from_response(text)) == 3
    end
  end

  # ── Regression: plans must never be scraped from prose ────────
  #
  # v1.0.046 defect: the agent answered a pure analysis question ("compare
  # Codex to our code") whose prose ended in a findings list "What OSA does
  # that Codex can't touch: 1..7". A `:post_response` hook named
  # "task_auto_extract" scraped that list into the session checklist and the
  # TUI rendered "Plan 0/3" — asserting outstanding work that did not exist.
  #
  # The tell was that it lifted items 4, 6 and 7 only: a NON-CONTIGUOUS subset.
  # That is exactly what the `String.length(t) <= 120` filter in
  # extract_from_response/1 does — items 1, 2, 3 and 5 were longer than 120
  # chars and were silently dropped, leaving 3 survivors, which cleared the
  # hook's `length(titles) >= 3` threshold.
  #
  # Fix: the hook is gone. A plan may only come from an explicit tool call.

  describe "no plan inference from prose (regression)" do
    @findings_prose """
    Here is the comparison you asked for.

    What OSA does that Codex can't touch:

    1. Multi-agent fleet orchestration with real supervision trees, live agent census, and per-agent token accounting across the whole fleet at once.
    2. Persistent session memory that survives restarts, with compaction safety and a restore path that replays tool calls rather than just transcript text.
    3. A pluggable provider registry that hot-swaps models mid-session without dropping the conversation or losing the tool-call history.
    4. Channels. channels/ — OSA can talk via Telegram, Discord, Slack. Codex is terminal-only.
    5. Sandboxing policy expressed as data rather than code, so the same policy object drives the shell tool, the browser tool, and the delegate tool uniformly.
    6. Healing and self-repair. healing/ directory — OSA has self-healing mechanisms. Codex doesn't.
    7. Speculative execution. speculative/ — OSA can start working on predicted next tasks. Codex can't.
    """

    test "the auto-extract post_response hook is not registered" do
      hooks = OptimalSystemAgent.Agent.Hooks.list_hooks()
      post_response = Map.get(hooks, :post_response, [])
      names = Enum.map(post_response, & &1.name)

      refute "task_auto_extract" in names,
             "a :post_response hook is scraping plans out of assistant prose; " <>
               "plans must come from an explicit tool call only"
    end

    test "running post_response hooks over findings prose creates no tasks" do
      sid = session_id()

      # Sanity: the session starts with an empty checklist.
      assert Tasks.get_tasks(sid) == []

      OptimalSystemAgent.Agent.Hooks.run(:post_response, %{
        session_id: sid,
        response: @findings_prose
      })

      # Give any (unwanted) async hook a chance to fire before asserting.
      Process.sleep(50)

      assert Tasks.get_tasks(sid) == [],
             "answering a question must not populate the plan/checklist"
    end

    test "prose findings still parse to the non-contiguous 4/6/7 subset" do
      # Documents WHY scraping is unsafe, and pins the mechanism that produced
      # the observed defect. This helper is pure and opt-in; nothing calls it
      # on a response automatically.
      titles = Tracker.extract_from_response(@findings_prose)

      assert length(titles) == 3
      assert Enum.any?(titles, &String.starts_with?(&1, "Channels."))
      assert Enum.any?(titles, &String.starts_with?(&1, "Healing and self-repair."))
      assert Enum.any?(titles, &String.starts_with?(&1, "Speculative execution."))

      # Items 1, 2, 3 and 5 exceed the 120-char cap and vanish — which is how a
      # 7-item findings list became a 3-item "plan".
      refute Enum.any?(titles, &String.starts_with?(&1, "Multi-agent fleet"))
      refute Enum.any?(titles, &String.starts_with?(&1, "Sandboxing policy"))

      # And none of these are actions — they are descriptive statements.
      assert Enum.all?(titles, &String.contains?(&1, "Codex"))
    end

    test "explicit add_tasks is still the supported path" do
      {_pid, name} = start_tracker()
      sid = session_id()

      assert {:ok, ids} = Tasks.add_tasks(sid, ["Run the test suite", "Fix the failing case"], name)
      assert length(ids) == 2

      tasks = Tasks.get_tasks(sid, name)
      assert length(tasks) == 2
      assert Enum.map(tasks, & &1.title) == ["Run the test suite", "Fix the failing case"]
    end
  end
end
