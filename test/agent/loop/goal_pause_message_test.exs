defmodule OptimalSystemAgent.Agent.Loop.GoalPauseMessageTest do
  @moduledoc """
  A goal-paused turn must say WHY it is paused, not always claim a stall — and
  the halt that says so must NEVER swallow a turn the user just started.

  Reported #1: a turn that walks into `GoalTracker.paused?/1 == true` with
  `pause_reason: :user` (a manual `/goal pause`, or the TUI's own
  interrupt-driven pause) got the SAME hardcoded halt text as a genuine stall
  — "no measurable progress across turns" — which is self-contradictory when
  a human paused it, and equally wrong for `:run_cap` / `:usage_limits`,
  neither of which is a stall either. (Fixed: `goal_pause_halt_message/1`.)

  Reported #2 (live, v1.0.183): with a goal paused, a user's OWN fresh
  message ("hey so u remember where we were... just tell me the status", then
  "EXCUSE ME") got NOTHING but this halt's canned notice, twice in a row —
  the turn never ran at all. The halt fired at `iteration == 0`, the exact
  shape of a brand-new top-level turn that has not called the model even
  once — indistinguishable, at that point, from the user's own fresh prompt.
  Scoped to `iter > 0`: a turn ALREADY in flight (this goal's own paused
  machinery interrupting its own further continuation) still halts; a turn
  that has not started yet never does — see the "never swallows a fresh user
  turn" tests below.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.ReactLoop

  defp sid, do: "goal-pause-msg-#{System.unique_integer([:positive])}"

  # `iteration: 1` — past this turn's first model call — is what the halt
  # still legitimately covers post-fix; see the "never swallows a fresh user
  # turn" tests below for the `iteration: 0` (fresh turn) side of the fix.
  defp base_state(session_id) do
    %{
      session_id: session_id,
      iteration: 1,
      messages: [%{role: "user", content: "keep going"}]
    }
  end

  # A full `Loop` struct, mock-provider-backed, so the turn can actually reach
  # a (fake) model call instead of halting before it — what "the prompt is
  # processed, not swallowed" has to mean in a test.
  defp fresh_turn_state(session_id, content) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: session_id,
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      messages: [%{role: "user", content: content}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  setup do
    prev = Application.fetch_env(:optimal_system_agent, :goal_tracker_enabled)
    # Force the tracker on regardless of autonomous posture — a `:paused`
    # goal is (by design) no longer a `goal_loop?/1`, so `:auto` resolution
    # would skip the very branch under test.
    Application.put_env(:optimal_system_agent, :goal_tracker_enabled, true)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :goal_tracker_enabled, v)
        :error -> Application.delete_env(:optimal_system_agent, :goal_tracker_enabled)
      end
    end)

    :ok
  end

  setup do
    saved =
      for key <- [:default_provider, :mock_provider_final_text],
          into: %{},
          do: {key, Application.fetch_env(:optimal_system_agent, key)}

    prev_env = System.get_env("OSA_DEFAULT_PROVIDER")
    System.put_env("OSA_DEFAULT_PROVIDER", "mock")
    Application.put_env(:optimal_system_agent, :default_provider, :mock)

    Application.put_env(
      :optimal_system_agent,
      :mock_provider_final_text,
      "Here is the status you asked for."
    )

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

  describe "the halt message names the actual pause reason" do
    test "a genuine stall says so" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :no_progress)

      {message, _state} = ReactLoop.run(base_state(s))
      assert message =~ "no measurable progress"

      GoalTracker.reset(s)
    end

    test "a manual/user pause does not claim a stall" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :user)

      {message, _state} = ReactLoop.run(base_state(s))

      refute message =~ "no measurable progress",
             "a user-initiated pause must not be reported as a stall: #{message}"

      assert message =~ "not a stall"

      GoalTracker.reset(s)
    end

    test "a spent lifetime verification-run cap says so, not a stall" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :run_cap)

      {message, _state} = ReactLoop.run(base_state(s))
      refute message =~ "no measurable progress"
      assert message =~ "verification-run cap"

      GoalTracker.reset(s)
    end

    test "a spent token budget says so, not a stall" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :usage_limits)

      {message, _state} = ReactLoop.run(base_state(s))
      refute message =~ "no measurable progress"
      assert message =~ "token budget"

      GoalTracker.reset(s)
    end
  end

  describe "the halt never swallows a fresh user turn" do
    test "a paused goal still lets a brand-new user prompt run and get answered" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :user)
      assert GoalTracker.paused?(s)

      {response, _state} =
        ReactLoop.run(
          fresh_turn_state(s, "hey so u remember where we were... just tell me the status")
        )

      assert response == "Here is the status you asked for.",
             "the user's real prompt must reach the model, not the goal-pause notice: #{response}"

      refute response =~ "Goal paused"
      refute response =~ "not a stall"

      GoalTracker.reset(s)
    end

    test "a SECOND fresh prompt right after also runs — the pause does not stick to the input lane" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :user)

      {first, _} = ReactLoop.run(fresh_turn_state(s, "what's the status"))
      assert first == "Here is the status you asked for."

      {second, _} = ReactLoop.run(fresh_turn_state(s, "EXCUSE ME"))
      assert second == "Here is the status you asked for."
      refute second =~ "Goal paused"

      GoalTracker.reset(s)
    end

    test "the goal is untouched by the user's turn running — still paused, /goal off still required to forget it" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :user)

      {_response, _state} = ReactLoop.run(fresh_turn_state(s, "what's the status"))

      assert GoalTracker.paused?(s),
             "answering the user must not silently resume or clear the paused goal"

      GoalTracker.reset(s)
    end

    test "a turn ALREADY in flight (iteration > 0) still halts — only fresh turns are exempt" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :user)

      {message, _state} = ReactLoop.run(base_state(s))

      assert message =~ "not a stall",
             "the goal's own mid-turn continuation must still stop when paused"

      GoalTracker.reset(s)
    end
  end
end
