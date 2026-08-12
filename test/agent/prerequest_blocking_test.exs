defmodule OptimalSystemAgent.Agent.PrerequestBlockingTest do
  @moduledoc """
  Two pieces of blocking I/O sat on the path between "the user pressed Enter"
  and "the request left the process", each behind a FIVE SECOND timeout.

  Neither is expensive on a healthy machine — that is exactly why they survived.
  What they carry is a tail: a sick sidecar turns a prompt submission into a
  multi-second stall with nothing on screen but a spinner, and the operator
  cannot tell that apart from the model thinking.

  Every reference harness defers this class of work rather than trusting it to
  be fast. codex writes its rollout through a dedicated writer task over a
  channel and comments the rule outright; Claude Code `void`s its snapshot and
  fires its titler as a bare `.then()`. Neither awaits anything before the
  provider call.

    1. `FSCheckpoint.Server.head/0` — a `GenServer.call` (5s) into a handler
       that shells out to `git rev-parse`, taken on every prompt because the
       rewind checkpoint pins the shadow-repo HEAD. The shell-out was ~2.5ms;
       the real hazard was the MAILBOX, since the same server serves
       `:snapshot`, which runs `git add` + `git commit` over a working tree.
       HEAD now lives in an ETS table the server publishes on every mutation.

    2. the embedding round-trip inside `Memory.recall_hybrid/2`, called from
       `Agent.Context` while assembling the prompt, with a 5s receive timeout.
       The vector score is optional — the function already falls back to pure
       lexical recall when there is no embedder — so prompt assembly now takes
       the lexical answer past a tight deadline.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.FSCheckpoint.Server, as: FSCheckpoint

  # ── 1. HEAD must not queue behind the server ────────────────────────────

  describe "FSCheckpoint.Server.head/0" do
    test "answers while the server is busy, instead of queueing behind it" do
      # Prime the published value the way a live process would.
      expected = FSCheckpoint.head()

      # Stand in for a long `:snapshot`: the process is alive but will not
      # service its mailbox. A `GenServer.call` against it now blocks for its
      # full timeout — 5 seconds for the old `head/0` — and then returns nil,
      # silently losing the fs pin as well as the time.
      :sys.suspend(FSCheckpoint)

      {elapsed_us, got} =
        try do
          :timer.tc(fn -> FSCheckpoint.head() end)
        after
          :sys.resume(FSCheckpoint)
        end

      assert got == expected,
             "a busy server must not change the answer, only the wait"

      assert elapsed_us < 250_000,
             "head/0 took #{div(elapsed_us, 1000)}ms with the server busy — it is " <>
               "queueing on the mailbox again"
    end

    test "the published value tracks the real repo HEAD" do
      path = OptimalSystemAgent.FSCheckpoint.Config.repo_path()

      assert {:ok, cached} = FSCheckpoint.cached_head(path),
             "the server must publish HEAD at init, or every first read pays the call"

      assert cached == FSCheckpoint.head()
    end
  end

  # ── 2. Prompt-time embedding must be deadlined ──────────────────────────

  describe "Memory.recall_hybrid/2 embedding deadline" do
    setup do
      prev_fun = Application.get_env(:optimal_system_agent, :embedding_fun)
      prev_provider = Application.get_env(:optimal_system_agent, :embedding_provider)

      # A wedged embedder: alive, answering, just far too late to be waited on.
      Application.put_env(:optimal_system_agent, :embedding_provider, :ollama)

      Application.put_env(:optimal_system_agent, :embedding_fun, fn _text ->
        Process.sleep(3_000)
        {:ok, [1.0, 2.0, 3.0]}
      end)

      on_exit(fn ->
        if prev_fun do
          Application.put_env(:optimal_system_agent, :embedding_fun, prev_fun)
        else
          Application.delete_env(:optimal_system_agent, :embedding_fun)
        end

        if prev_provider do
          Application.put_env(:optimal_system_agent, :embedding_provider, prev_provider)
        else
          Application.delete_env(:optimal_system_agent, :embedding_provider)
        end
      end)

      :ok
    end

    test "a deadline caps the wait and still returns the lexical answer" do
      {elapsed_us, result} =
        :timer.tc(fn ->
          OptimalSystemAgent.Memory.recall_hybrid("deployment configuration notes",
            limit: 5,
            embed_deadline_ms: 100
          )
        end)

      assert {:ok, entries} = result
      assert is_list(entries)

      assert elapsed_us < 1_500_000,
             "prompt-time recall waited #{div(elapsed_us, 1000)}ms on the embedder — " <>
               "the deadline is not being applied"
    end

    test "without the option the full provider timeout still applies" do
      # The tools that exist to search memory must keep their budget; the
      # deadline is scoped to prompt assembly, not bolted onto everyone.
      {elapsed_us, {:ok, _}} =
        :timer.tc(fn ->
          OptimalSystemAgent.Memory.recall_hybrid("deployment configuration notes", limit: 5)
        end)

      assert elapsed_us > 2_000_000,
             "the un-deadlined path should still have waited for the embedder; got " <>
               "#{div(elapsed_us, 1000)}ms — this test's premise (that the embedder is " <>
               "actually reached) is broken"
    end
  end
end
