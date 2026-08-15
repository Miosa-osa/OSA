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

    # `:read_unchanged_suppression` is the one flag exempt from this, and the
    # exemption is a measured finding rather than a carve-out. Byte-identical
    # suppression fires only on a repeat of a window ALREADY delivered — 19 of
    # 1,142 calls and 0.8% of read payload across 118 transcripts. Range
    # subtraction reaches the same calls by a wider route (a window whose held
    # overlap is total has no remainder to send), so with subtraction shipped,
    # ablating byte-identical suppression alone moves nothing on the line axis.
    #
    # It stays wired because it is still the only mechanism on the BYTE axis,
    # where subtraction does not apply — mixing line intervals and byte offsets
    # is not sound arithmetic. This corpus has no identical byte-slice repeat to
    # exercise that, and inventing one to keep a table row non-zero would be
    # measuring the fixture.
    @subsumed_flags [:read_unchanged_suppression]

    test "every flag moves either tokens or a probe verdict", %{dir: dir} do
      %{rows: rows} = Runner.run(dir: dir)

      for row <- rows, row.flag not in @subsumed_flags do
        moved_tokens? = row.tokens_with != row.tokens_without
        moved_probes? = row.regressions != [] or row.improvements != []

        assert moved_tokens? or moved_probes?,
               "#{row.flag} changed nothing when ablated — its guard is no longer " <>
                 "wired to anything, and the ablation is silently reporting it free"
      end
    end

    test "range subtraction pays for itself and costs no fact", %{dir: dir} do
      %{rows: [row]} = Runner.run(dir: dir, flags: [:read_range_subtraction])

      assert row.tokens_without > row.tokens_with,
             "removing range subtraction no longer costs tokens — either it stopped " <>
               "firing, or no scenario overlaps a window it already read"

      assert row.regressions == [],
             "range subtraction withheld a fact: #{inspect(row.regressions)}"
    end

    test "stamps are what make 'did the file end?' answerable", %{dir: dir} do
      %{rows: [row]} = Runner.run(dir: dir, flags: [:read_stamps])

      probes = Enum.map(row.regressions, & &1.probe)

      assert :is_this_the_end in probes,
             "removing the EOF stamp no longer costs the decisive fact — either the " <>
               "stamp moved, or the probe stopped depending on it"
    end

    test "the per-line clamp now saves a great deal and costs nothing", %{dir: dir} do
      %{rows: [row]} = Runner.run(dir: dir, flags: [:read_line_clamp])

      assert row.tokens_without > row.tokens_with * 5,
             "removing the clamp is no longer catastrophically expensive"

      # This assertion is INVERTED from what it was, and the inversion is the
      # finding. The clamp used to destroy three facts outright — the end of a
      # minified file, a base64 blob's decodability, a deep JSON leaf — so
      # ablating it RECOVERED them and the row showed improvements. That was the
      # signature of a truncation with no undo: the tail of a clamped line was
      # unreachable by any subsequent call, because `offset`/`limit` address
      # lines and the line was already fully selected.
      #
      # `byte_offset` is the missing axis, and the clamp notice names the exact
      # byte it stopped at. With a way back, ablating the clamp recovers nothing
      # that was not already recoverable, and the row is what a good trade looks
      # like: a large saving with an empty cost column. If improvements ever
      # reappear here, the recovery path has broken and the clamp is destroying
      # information again.
      assert row.improvements == [],
             "ablating the clamp recovered #{inspect(Enum.map(row.improvements, & &1.probe))} " <>
               "— those facts are reachable only when the clamp is OFF, which means the " <>
               "byte_offset recovery path no longer works"
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
