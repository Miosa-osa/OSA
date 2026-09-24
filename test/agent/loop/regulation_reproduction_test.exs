defmodule OptimalSystemAgent.Agent.Loop.RegulationReproductionTest do
  @moduledoc """
  End-to-end reproduction of the incident the regulation core was built for:
  a turn that repeats a near-identical read-only probe instead of converging.

  Drives the REAL `ReactLoop.run/1` against `MockProvider`, scripted to answer
  every round-trip with the SAME `file_read` call on the SAME file — the
  "re-verifying a fact the user had stated" shape from the motivating
  incident, minus the 18 minutes.

  What this establishes:

    * pain rises as the identical probe repeats (`Regulation.Pain`'s score,
      observed via the `pain_alert` broadcasts it puts on the session's
      `osa:session:<id>` PubSub topic — the exact channel the TUI streams);
    * an alarm is visible well before the turn ends, not only in the log;
    * the turn does NOT run to `max_iterations` — SOMETHING pauses it early,
      which is the point: an operator watching this turn sees it get flagged
      long before it would otherwise grind to the iteration ceiling.

  It does not assert that regulation itself, rather than the pre-existing
  identical-call doom-loop guard, is what ends this SPECIFIC turn — with the
  default 4-in-a-row consecutive threshold, `DoomLoop.IdenticalCall` halts
  first (see `regulation/pain_test.exs` for a direct, deterministic proof
  that `Pain.evaluate/3` itself pauses the turn at `:critical` severity).
  What matters here is that the NEW channel is already lit up, with a rising
  score, before that older guard's halt text is all the operator would have
  seen.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  @keys ~w(default_provider mock_provider_final_text mock_provider_tool_calls
           max_iterations doom_loop_resample regulation_pain)a

  setup do
    saved =
      for key <- @keys, into: %{}, do: {key, Application.fetch_env(:optimal_system_agent, key)}

    tmp =
      Path.join(System.tmp_dir!(), "regulation-repro-#{System.unique_integer([:positive])}.txt")

    File.write!(tmp, "the same fact, every time\n")

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :max_iterations, 20)
    # Isolates what this test is about: repeats, not the resample remedy
    # (covered by `doom_loop_resample_test.exs`) re-rolling on top of them.
    Application.put_env(:optimal_system_agent, :doom_loop_resample, enabled: false)
    # Deliberately low so a handful of repeats is enough to reach `:high`/
    # `:critical` within this short scripted run, without needing dozens of
    # round-trips to prove the score climbs.
    Application.put_env(:optimal_system_agent, :regulation_pain,
      enabled: true,
      low_at: 0.05,
      medium_at: 0.10,
      question_at: 0.20,
      pause_at: 0.30,
      min_emit_interval_ms: 0
    )

    Application.put_env(:optimal_system_agent, :mock_provider_final_text, "")

    Application.put_env(:optimal_system_agent, :mock_provider_tool_calls, [
      %{id: "call_probe", name: "file_read", arguments: %{"path" => tmp}}
    ])

    MockProvider.reset()
    MockProvider.reset_round_trips()

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, v}} -> Application.put_env(:optimal_system_agent, key, v)
        {key, :error} -> Application.delete_env(:optimal_system_agent, key)
      end)

      File.rm(tmp)
    end)

    %{tmp: tmp}
  end

  defp sid, do: "regulation-repro-#{System.unique_integer([:positive])}"

  defp base_state(session_id) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: session_id,
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      messages: [%{role: "user", content: "what does the config say about the timeout?"}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
    |> OptimalSystemAgent.Agent.Loop.TurnPipeline.reset_per_turn_fields()
  end

  defp drain_pain_alerts(acc \\ []) do
    receive do
      {:osa_event, %{type: :system_event, event: :pain_alert} = payload} ->
        drain_pain_alerts([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "an identical read-only probe raises pain, surfaces an alarm, and the turn pauses early" do
    session_id = sid()
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    {response, _state} = ReactLoop.run(base_state(session_id))

    assert is_binary(response)

    alerts = drain_pain_alerts()

    assert alerts != [],
           "expected at least one pain_alert broadcast on the session's PubSub topic — " <>
             "the regulation core surfaced nothing while the probe repeated"

    severities = Enum.map(alerts, & &1.severity)
    refute Enum.all?(severities, &(&1 == "none")), "every alert reported :none severity"

    scores = Enum.map(alerts, & &1.score)

    assert Enum.max(scores) > Enum.min(scores),
           "pain score never rose across the repeated probe — got #{inspect(scores)}"

    Enum.each(alerts, fn alert ->
      assert String.starts_with?(alert.message, "stuck:"),
             "alarm text was not the plain-language cause line: #{inspect(alert.message)}"
    end)

    # SOMETHING paused this well short of the 20-iteration ceiling — proof
    # the turn was flagged and stopped rather than left to grind on.
    assert MockProvider.round_trips() < 10,
           "expected an early pause on the repeated probe, got #{MockProvider.round_trips()} " <>
             "round-trips"
  end
end
