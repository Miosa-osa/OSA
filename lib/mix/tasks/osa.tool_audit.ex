defmodule Mix.Tasks.Osa.ToolAudit do
  @shortdoc "Price every tool in the array by removing it, against the call record"

  @moduledoc """
  Sibling of `mix osa.ablate`. That one prices a read-tool OUTPUT feature by
  removing it; this one prices a whole TOOL by removing it from the provider
  `tools` array.

      mix osa.tool_audit
      mix osa.tool_audit --remove file_transform,delegate
      mix osa.tool_audit --corpus bench/terminalbench/runs --json /tmp/audit.json

  Offline and free. No provider is contacted: the schema cost comes from the
  live `Registry.list_active/0` array serialized exactly as
  `Providers.Anthropic` sends it, and the call counts come from the transcripts
  already on disk.

  ## Reading the table

  `Δ rm` is the prefix tokens REMOVING the tool buys back, every turn, forever —
  measured by difference on the real array, so inter-element JSON punctuation is
  counted rather than dropped.

  `calls` is what the corpus records the model actually doing, from structured
  tool-call rows only. `fail%` matters as much: a tool called often and failing
  often is worse than one never called, because a failure costs a round trip AND
  the tokens of the error.

  `arr` says whether the tool is in the default array at all, and `rch` whether
  `tool_search` can resolve it if it is not. Those two columns are what separate
  "the model never wanted it" from "the API could not emit its name" — and a
  zero in `calls` means nothing until you have read them.

  ## What this cannot tell you

  The corpus is what has been run, and what has been run is overwhelmingly
  benchmark containers. A container never asks a question, never hands work to a
  person and never resumes yesterday's session, so a conversational tool reading
  zero here has not been measured — it has been excluded by the sampling frame.
  Frequency is not importance. The table is evidence for a proposal; only
  unreachability, duplication, and measured breakage are evidence for a cut.
  """

  use Mix.Task

  alias OptimalSystemAgent.Tools.Audit

  @requirements ["app.config"]

  @default_roots [
    {"swebench", "bench/swebench/runs"},
    {"swebenchpro", "bench/swebenchpro/runs"},
    {"terminalbench", "bench/terminalbench/runs"},
    {"headtohead", "bench/headtohead/runs"},
    {"recoverybench", "bench/recoverybench/runs"},
    {"sessions", "~/.osa/sessions"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [corpus: :keep, remove: :string, json: :string, all: :boolean]
      )

    Mix.Task.run("app.start")
    # The registry registers builtins asynchronously at boot; asking before it
    # settles reports a short array and silently understates every figure.
    Process.sleep(1_500)

    roots = roots_from(opts)
    Mix.shell().info("\nScanning #{length(roots)} corpora…")
    census = Audit.census(roots)

    rows = Audit.rows(census)
    active = OptimalSystemAgent.Tools.Registry.list_active()
    total = Audit.array_cost(active)

    print_summary(census, rows, active, total)
    print_table(rows, opts[:all])
    print_phantoms(census)
    print_ranked(rows, total)
    if opts[:remove], do: print_cut(active, opts[:remove], total)

    if opts[:json] do
      File.write!(
        opts[:json],
        Jason.encode!(%{census: census, rows: rows, array: total}, pretty: true)
      )

      Mix.shell().info("\nWrote #{opts[:json]}")
    end

    :ok
  end

  defp roots_from(opts) do
    case Keyword.get_values(opts, :corpus) do
      [] -> @default_roots
      dirs -> Enum.map(dirs, &{Path.basename(Path.expand(&1)), &1})
    end
    |> Enum.map(fn {label, dir} -> {label, Path.expand(dir)} end)
    |> Enum.filter(fn {_, dir} -> File.dir?(dir) end)
  end

  defp print_summary(census, rows, active, total) do
    registered = length(rows)
    files = census |> Map.values() |> Enum.map(& &1.__meta__.files) |> Enum.sum()
    sessions = census |> Map.values() |> Enum.map(& &1.__meta__.sessions) |> Enum.sum()
    calls = rows |> Enum.map(& &1.calls) |> Enum.sum()

    Mix.shell().info("""

    ── Tool audit ────────────────────────────────────────────────────────
    Registry: #{length(active)} of #{registered} registered tools are in the
    default array. That array is #{total.bytes} bytes / ~#{total.tokens} tokens,
    re-sent on every request of every turn.

    Corpus: #{files} transcripts, #{sessions} with at least one tool call,
    #{calls} calls attributed to a registered tool.

    #{pad("tool", 22)}#{rp("arr", 5)}#{rp("rch", 5)}#{rp("calls", 8)}#{rp("share", 7)}#{rp("fail%", 7)}#{rp("bytes", 8)}#{rp("Δ rm", 7)}\
    """)
  end

  defp print_table(rows, all?) do
    total_calls = rows |> Enum.map(& &1.calls) |> Enum.sum() |> max(1)

    rows
    |> Enum.filter(fn r -> all? || r.active || r.calls > 0 end)
    |> Enum.sort_by(&{-&1.calls, -&1.removal.tokens})
    |> Enum.each(fn r ->
      attempts = r.ok + r.fail

      failpct =
        if attempts > 0, do: "#{round(r.fail * 100 / attempts)}%", else: "-"

      Mix.shell().info(
        pad(r.name, 22) <>
          rp(if(r.active, do: "yes", else: "no"), 5) <>
          rp(if(r.reachable, do: "yes", else: "NO"), 5) <>
          rp(to_string(r.calls), 8) <>
          rp("#{Float.round(r.calls * 100 / total_calls, 1)}%", 7) <>
          rp(failpct, 7) <>
          rp(to_string(r.removal.bytes), 8) <>
          rp(to_string(r.removal.tokens), 7)
      )
    end)
  end

  defp print_phantoms(census) do
    case Audit.phantoms(census) do
      [] ->
        :ok

      list ->
        Mix.shell().info("""

        ── Names called that no tool answers to ──────────────────────────────
        Each is a wasted round trip. A name the model reaches for repeatedly is
        an argument about what the tool should have been called.\
        """)

        Enum.each(list, fn {n, c} -> Mix.shell().info("  #{rp(to_string(c), 6)}  #{n}") end)
    end
  end

  defp print_ranked(rows, total) do
    Mix.shell().info("""

    ── Ranked by tokens per call ─────────────────────────────────────────
    Array tokens the tool costs every turn, divided by the calls the corpus
    records. A high number is a schema being paid for and not used; it is an
    argument to DEFER, and only an argument to delete once the columns above
    say the model could have called it and chose not to.\
    """)

    rows
    |> Enum.filter(& &1.active)
    |> Enum.sort_by(fn r -> -cost_per_call(r) end)
    |> Enum.each(fn r ->
      cpc =
        if r.calls > 0,
          do: "#{Float.round(r.removal.tokens / r.calls, 2)}",
          else: "never called"

      Mix.shell().info(
        "  #{pad(r.name, 22)}#{rp(to_string(r.removal.tokens), 7)} tok  #{rp(to_string(r.calls), 7)} calls   #{cpc}"
      )
    end)

    Mix.shell().info("\n  Array total: #{total.tokens} tokens.")
  end

  defp cost_per_call(%{calls: 0, removal: %{tokens: t}}), do: t * 1_000_000
  defp cost_per_call(%{calls: c, removal: %{tokens: t}}), do: t / c

  defp print_cut(active, spec, total) do
    names = String.split(spec, ",", trim: true) |> Enum.map(&String.trim/1)
    cut = Audit.cut_cost(active, names)

    Mix.shell().info("""

    ── Candidate cut ─────────────────────────────────────────────────────
    Removing #{length(names)} tools (#{Enum.join(names, ", ")}):
      #{cut.bytes} bytes / ~#{cut.tokens} tokens off a #{total.tokens}-token array
      (#{round(cut.tokens * 100 / max(total.tokens, 1))}%), leaving #{cut.remaining} tools.

    Measured as a joint difference on the real array. It happens to equal the
    sum of the individual removals — an n-element array has n-1 separators, so
    each removal drops exactly one — but the joint figure is the one reported,
    so the number does not depend on that staying true.\
    """)
  end

  defp pad(s, n), do: String.pad_trailing(to_string(s), n)
  defp rp(s, n), do: String.pad_leading(to_string(s), n)
end
