defmodule Mix.Tasks.Osa.Cadence.Replay do
  @shortdoc "Replay recorded sessions through the batching-nudge predicate"

  @moduledoc """
  Offline replay: would the batching nudge have fired, and on which turns?

      mix osa.cadence.replay
      mix osa.cadence.replay --dir ~/.osa/sessions --min-turns 15

  ## Why a replay and not an A/B

  The intervention this measures is a late-context reminder appended after tool
  results when the last N turns were all single-call. The thing it is fighting —
  batch rate decaying from 0.34 at turn 0 to 0.04 at turn 15+, with an 8x
  self-conditioning on the previous turn — lives at turn 15 and beyond, and gets
  worse out to turn 230.

  The A/B that failed to move batching with prompt guidance could only reach
  13–16 turn sessions. It therefore never observed the regime, and neither would
  a re-run of it. Live provider access is currently unavailable here (Ollama
  quota exhausted, `.env` empty), so an online experiment is not on the table at
  all.

  What IS available is 465 recorded sessions containing 7,038 tool-bearing
  turns, 75 of which run past 30 turns and one to 232. Replaying the **real**
  predicate — `Agent.BatchCadence`, the same module the live loop calls, not a
  copy of its rules — over those transcripts answers the questions that decide
  whether the mechanism is wired correctly:

    * does it reach the regime, or does it all fire in the first ten turns?
    * how often does it speak per session, and does it stop?
    * does it fire on sessions that already batch (where it would be noise)?

  ## What it CANNOT answer

  Whether the model then batches. That is a causal question about a model's
  response and no replay of past transcripts can reach it: those turns were
  produced without ever seeing the reminder. Every number below is about
  **delivery** — when the nudge would appear — and none is about **effect**.
  Reporting it any other way would be the second time an artefact was published
  as a result, which is what the ablation harness exists to prevent.

  ## Turn index

  The live nudge reads `state.iteration`. The replay uses the ordinal of the
  tool-bearing turn within the session, which is the same quantity except that
  text-only turns do not advance it. That makes the replay's turn indices a
  slight UNDER-estimate of the live ones, so a nudge the replay places at turn
  20 lands at or after turn 20 live — the direction that cannot manufacture
  firings in the regime this is trying to observe.
  """

  use Mix.Task

  alias OptimalSystemAgent.Agent.BatchCadence

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [dir: :string, min_turns: :integer, limit: :integer]
      )

    Mix.Task.run("app.start")

    dir = Path.expand(opts[:dir] || Path.join([System.user_home!(), ".osa", "sessions"]))
    min_turns = opts[:min_turns] || 1

    sessions =
      dir
      |> Path.join("*.updates.jsonl")
      |> Path.wildcard()
      |> then(fn files -> if opts[:limit], do: Enum.take(files, opts[:limit]), else: files end)
      |> Enum.map(&{Path.basename(&1), batch_sizes(&1)})
      |> Enum.reject(fn {_name, sizes} -> length(sizes) < min_turns end)

    BatchCadence.reset()
    replays = Enum.map(sessions, &replay/1)

    report(dir, min_turns, replays)
  end

  # Tool-call counts per tool-bearing assistant turn, in order. Turns with no
  # tool calls are dropped: the orchestrator never sees them, so the live
  # tracker never records them either.
  defp batch_sizes(file) do
    file
    |> File.stream!()
    |> Stream.map(&decode/1)
    |> Stream.flat_map(fn
      %{"msg" => %{"role" => "assistant", "tool_calls" => calls}} when is_list(calls) ->
        if calls == [], do: [], else: [length(calls)]

      _ ->
        []
    end)
    |> Enum.to_list()
  rescue
    _ -> []
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  # Drive the REAL predicate, in the REAL order: the live loop records a turn's
  # batch in `ToolOrchestrator.dispatch/3` and then asks `nudge?/2` while
  # appending reminders to that same turn's results.
  defp replay({name, sizes}) do
    sid = "replay-" <> name

    fires =
      sizes
      |> Enum.with_index()
      |> Enum.flat_map(fn {count, turn} ->
        BatchCadence.record(sid, count)
        if BatchCadence.nudge?(sid, turn), do: [turn], else: []
      end)

    %{
      name: name,
      turns: length(sizes),
      batched_turns: Enum.count(sizes, &(&1 > 1)),
      fires: fires
    }
  end

  defp report(dir, min_turns, replays) do
    turns = Enum.reduce(replays, 0, &(&1.turns + &2))
    batched = Enum.reduce(replays, 0, &(&1.batched_turns + &2))
    fired = Enum.filter(replays, &(&1.fires != []))
    all_fires = Enum.flat_map(replays, & &1.fires)

    never_batched = Enum.filter(replays, &(&1.batched_turns == 0))
    long = Enum.filter(replays, &(&1.turns >= 30))

    IO.puts("""

    ── Batching-nudge replay (offline; delivery only, NOT effect) ─────────
    corpus: #{dir}
    sessions (>= #{min_turns} tool-bearing turns): #{length(replays)}
    tool-bearing turns:                            #{turns}
    turns that batched (>1 call):                  #{batched} (#{pct(batched, turns)})

    rule: #{BatchCadence.window()} consecutive single-call turns, not before turn \
    #{BatchCadence.min_turn()}, cooldown #{BatchCadence.cooldown()} turns and doubling, \
    #{BatchCadence.max_fires()} per session max

    sessions that would see a nudge:  #{length(fired)} (#{pct(length(fired), length(replays))})
    total nudges delivered:           #{length(all_fires)}
    nudges per session that got one:  #{avg(length(all_fires), length(fired))}
    nudges per tool-bearing turn:     #{rate(length(all_fires), turns)}
    """)

    IO.puts("turn index at which a nudge fires:")
    IO.puts("  " <> histogram(all_fires))

    IO.puts("""

    reaching the regime the failed A/B could not:
      sessions >= 30 tool turns:        #{length(long)}
      ... of which get a nudge:         #{Enum.count(long, &(&1.fires != []))}
      nudges landing at turn >= 15:     #{Enum.count(all_fires, &(&1 >= 15))} \
    (#{pct(Enum.count(all_fires, &(&1 >= 15)), length(all_fires))})
      longest session in corpus:        #{Enum.max_by(replays, & &1.turns, fn -> %{turns: 0} end).turns} turns

    noise check — sessions that ALREADY batch:
      sessions that never batched:      #{length(never_batched)}
      ... of which get a nudge:         #{Enum.count(never_batched, &(&1.fires != []))}
      sessions that did batch:          #{length(replays) - length(never_batched)}
      ... of which get a nudge:         \
    #{Enum.count(replays, &(&1.batched_turns > 0 and &1.fires != []))}
    """)
  end

  # Decade buckets, which is the resolution the decay curve was reported at.
  defp histogram([]), do: "(none)"

  defp histogram(fires) do
    fires
    |> Enum.frequencies_by(fn t -> div(t, 10) * 10 end)
    |> Enum.sort()
    |> Enum.map_join("  ", fn {bucket, n} -> "#{bucket}-#{bucket + 9}: #{n}" end)
  end

  defp pct(_n, 0), do: "0%"
  defp pct(n, total), do: "#{Float.round(n * 100 / total, 1)}%"

  defp avg(_n, 0), do: "0"
  defp avg(n, total), do: Float.round(n / total, 2)

  defp rate(_n, 0), do: "0"
  defp rate(n, total), do: Float.round(n / total, 4)
end
