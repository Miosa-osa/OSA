defmodule OptimalSystemAgent.Tools.AblationHarnessTest do
  @moduledoc """
  The harness is a measuring instrument, so the thing worth testing is that it
  still measures.

  Two failure modes matter more than any individual number:

    * **It stops affecting anything.** If a flag's guard is refactored out of a
      tool, `mix osa.ablate` keeps printing a table — all zeros, all "no
      regressions" — and reads as "every feature is free". A silent instrument
      is worse than none, because it is believed.

    * **It leaks into production.** These flags gate real tool output. If a
      value could escape the process that set it, an ablation run would degrade
      a live session's reads, and the bug would present as a model failure.

  Neither is caught by the harness's own output, which is why they are here.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Ablation
  alias OptimalSystemAgent.Tools.Ablation.Corpus
  alias OptimalSystemAgent.Tools.Ablation.Runner

  @moduletag :tmp_dir

  describe "flag plumbing" do
    test "every flag defaults to shipped behaviour outside a harness" do
      for flag <- Ablation.flags() do
        assert Ablation.on?(flag) == Map.fetch!(Ablation.defaults(), flag),
               "#{flag} does not read its production default"
      end
    end

    test "an unknown flag answers on, rather than raising on the tool hot path" do
      assert Ablation.on?(:no_such_flag_was_ever_defined)
    end

    test "overrides are restored even when the body raises" do
      assert_raise RuntimeError, fn ->
        Ablation.with_flags(%{read_stamps: false}, fn -> raise "boom" end)
      end

      assert Ablation.on?(:read_stamps),
             "a raising ablation case contaminated every case after it"
    end

    test "overrides cannot escape the process that set them" do
      parent = self()

      Ablation.with_flags(%{read_stamps: false}, fn ->
        refute Ablation.on?(:read_stamps)

        task = Task.async(fn -> Ablation.on?(:read_stamps) end)
        send(parent, {:child, Task.await(task)})
      end)

      assert_received {:child, true},
                      "an ablation flag reached another process — it could reach a live session"
    end
  end

  describe "the corpus" do
    test "generates byte-identically twice", %{tmp_dir: tmp} do
      a = Corpus.build(Path.join(tmp, "a"))
      b = Corpus.build(Path.join(tmp, "b"))

      for name <- Corpus.names() do
        assert File.read!(Path.join(a, name)) == File.read!(Path.join(b, name)),
               "#{name} is not deterministic — deltas across runs would be noise"
      end
    end

    test "the files are actually hostile", %{tmp_dir: tmp} do
      dir = Corpus.build(tmp)

      minified = File.read!(Path.join(dir, "minified.js"))
      assert byte_size(minified) > 500_000
      assert length(String.split(minified, "\n")) <= 2, "minified.js gained newlines"

      window = File.read!(Path.join(dir, "window_exact.txt"))

      assert length(String.split(String.trim_trailing(window, "\n"), "\n")) ==
               Corpus.exact_window(),
             "window_exact.txt no longer has exactly one window of lines — the " <>
               "EOF-vs-continuation case it exists for is gone"

      refute String.valid?(File.read!(Path.join(dir, "binary_adjacent.dat"))),
             "binary_adjacent.dat became valid UTF-8"
    end
  end

  describe "the instrument responds" do
    setup %{tmp_dir: tmp}, do: {:ok, dir: Path.join(tmp, "corpus")}

    test "every flag moves either tokens or a probe verdict", %{dir: dir} do
      %{rows: rows} = Runner.run(dir: dir)

      for row <- rows do
        moved_tokens? = row.tokens_with != row.tokens_without
        moved_probes? = row.regressions != [] or row.improvements != []

        assert moved_tokens? or moved_probes?,
               "#{row.flag} changed nothing when ablated — its guard is no longer " <>
                 "wired to anything, and the ablation is silently reporting it free"
      end
    end

    test "stamps are what make 'did the file end?' answerable", %{dir: dir} do
      %{rows: [row]} = Runner.run(dir: dir, flags: [:read_stamps])

      probes = Enum.map(row.regressions, & &1.probe)

      assert :is_this_the_end in probes,
             "removing the EOF stamp no longer costs the decisive fact — either the " <>
               "stamp moved, or the probe stopped depending on it"
    end

    test "the per-line clamp trades information for a large amount of money", %{dir: dir} do
      %{rows: [row]} = Runner.run(dir: dir, flags: [:read_line_clamp])

      assert row.tokens_without > row.tokens_with * 5,
             "removing the clamp is no longer catastrophically expensive"

      assert row.improvements != [],
             "the clamp is no longer destroying anything — if true that is good " <>
               "news, but it means this row's trade-off has changed and the " <>
               "recommendation attached to it needs revisiting"
    end

    test "baseline probes are mostly answerable, so regressions mean something", %{dir: dir} do
      %{scenarios: scenarios} = Runner.run(dir: dir, flags: [])

      verdicts = Enum.flat_map(scenarios, fn s -> Enum.map(s.probes, & &1.verdict) end)

      # A probe that is `:lost` at baseline cannot register a regression, so a
      # corpus where most probes start lost would report every feature as free.
      ok = Enum.count(verdicts, &(&1 == :ok))
      assert ok * 2 > length(verdicts), "most probes are unanswerable before any ablation"

      refute :wrong in verdicts,
             "a production default is returning a fact that is recoverable and WRONG"
    end
  end

  describe "file_transform vs file_read + file_edit" do
    test "the one-call route is cheaper and still reports what it did", %{tmp_dir: tmp} do
      t = Runner.transform_comparison(Path.join(tmp, "corpus"))

      assert t.route_b.calls < t.route_a.calls
      assert t.route_b.tokens < t.route_a.tokens

      assert t.route_b_reports_counts,
             "the cheap route stopped reporting per-operation counts, which is the " <>
               "only thing making it safe to use on a file you have not read"
    end
  end
end
