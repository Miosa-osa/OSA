defmodule Mix.Tasks.Osa.Ablate do
  @shortdoc "Price each file-tool output feature by removing it"

  @moduledoc """
  Run the read-tool ablation and print the table.

      mix osa.ablate
      mix osa.ablate --flag read_stamps
      mix osa.ablate --detail

  Offline and free. No provider is contacted; the corpus is generated on disk
  under the system temp directory and the real tool handlers are called
  directly.

  ## Reading the table

  `with` is always the feature PRESENT and `without` always absent, whichever
  of those is production — the `prod` column says which is shipped today. So a
  positive `Δ remove` on a `prod=on` row is what removing the feature WOULD
  save, and on a `prod=off` row it is what removing it ALREADY saved.

  `lost` is the column that decides. It counts probes that answered correctly
  with the feature and stopped answering without it. A row with a large positive
  `Δ remove` and zero `lost` is fat and should go; a row with `lost` bought
  something, and `--detail` says exactly what.
  """

  use Mix.Task

  alias OptimalSystemAgent.Tools.Ablation.Runner

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [flag: :keep, detail: :boolean, dir: :string])

    Mix.Task.run("app.start")

    flags =
      case Keyword.get_values(opts, :flag) do
        [] -> OptimalSystemAgent.Tools.Ablation.flags()
        names -> Enum.map(names, &String.to_existing_atom/1)
      end

    run_opts =
      [flags: flags] ++ if(opts[:dir], do: [dir: opts[:dir]], else: [])

    result = Runner.run(run_opts)

    print_header()
    Enum.each(result.rows, &print_row/1)
    print_transform(result.transform)
    if opts[:detail], do: print_detail(result)
    print_probe_baseline(result.scenarios)

    :ok
  end

  defp print_header do
    Mix.shell().info("""

    ── Read-tool ablation ────────────────────────────────────────────────
    Corpus: 10 files, 19 scenarios. Tokens are OSA's own estimator
    (no tokenizer binary in this tree); bytes are exact.

    `Δ remove` is what REMOVING the feature does to the bill: positive means
    removing it saves that many tokens, negative means removing it COSTS that
    many. `lost`/`gained` count probe facts that stopped or started being
    recoverable once it was removed.

    #{pad("feature", 28)}#{rpad("with", 9)}#{rpad("without", 9)}#{rpad("Δ remove", 17)}#{rpad("prod", 6)}#{rpad("lost", 6)}gained\
    """)
  end

  defp print_row(row) do
    saved = row.tokens_with - row.tokens_without
    pct = if row.tokens_with > 0, do: round(saved * 100 / row.tokens_with), else: 0

    Mix.shell().info(
      pad(to_string(row.flag), 28) <>
        rpad(to_string(row.tokens_with), 9) <>
        rpad(to_string(row.tokens_without), 9) <>
        rpad("#{saved} (#{pct}%)", 17) <>
        rpad(to_string(row.production), 6) <>
        rpad(to_string(length(row.regressions)), 6) <>
        to_string(length(row.improvements))
    )
  end

  defp print_transform(t) do
    Mix.shell().info("""

    ── file_transform vs file_read + file_edit (same 3 substitutions) ────
    route A (read + 3 edits): #{t.route_a.calls} calls, #{t.route_a.tokens} tok, #{t.route_a.bytes} B
    route B (1 transform):    #{t.route_b.calls} calls, #{t.route_b.tokens} tok, #{t.route_b.bytes} B
    saved by route B:         #{t.route_a.tokens - t.route_b.tokens} tok
    route B still reports per-operation counts: #{t.route_b_reports_counts}\
    """)
  end

  defp print_detail(result) do
    Mix.shell().info("\n── Per-flag probe detail ─────────────────────────────────────────────")

    Enum.each(result.rows, fn row ->
      Mix.shell().info("\n#{row.flag}:")

      case row.regressions ++ row.improvements do
        [] ->
          Mix.shell().info("  no probe changed verdict — nothing this feature was needed for")

        moves ->
          Enum.each(moves, fn r ->
            Mix.shell().info(
              "  #{r.scenario}/#{r.probe}: #{r.was} → #{r.became}\n    #{r.question}"
            )
          end)
      end
    end)
  end

  defp print_probe_baseline(scenarios) do
    Mix.shell().info("\n── Baseline probe verdicts (production defaults) ─────────────────────")

    Enum.each(scenarios, fn s ->
      verdicts =
        Enum.map_join(s.probes, "  ", fn p -> "#{p.id}=#{p.verdict}" end)

      Mix.shell().info("#{pad(to_string(s.id), 24)}#{rpad("#{s.tokens} tok", 12)}#{verdicts}")
    end)
  end

  defp pad(s, n), do: String.pad_trailing(s, n)
  defp rpad(s, n), do: String.pad_trailing(s, n)
end
