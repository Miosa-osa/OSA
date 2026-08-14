defmodule OptimalSystemAgent.Tools.Ablation.Corpus do
  @moduledoc """
  Nine deliberately hostile files, generated deterministically.

  ## What makes a file hostile

  Not size. A 60k-line file is merely large; every read tool handles it the
  same boring way. A file is hostile when it makes a tool's OUTPUT ambiguous —
  when the caller cannot tell, from what came back, what it is actually
  holding. Those are the cases where a feature either earns its tokens or does
  not, and they are the only cases where an ablation says anything.

  Each file below targets one specific ambiguity:

    1. `huge_flat.txt`        — cannot be read whole; every read is a window, so
                                "is there more?" is unanswerable from content.
    2. `minified.js`          — one 900 KB line. `limit: 1` still returns the
                                whole thing; line count is a lie about size.
    3. `mixed_widths.log`     — 3 pathological lines hidden among 5,000 normal
                                ones, so a per-line cap either fires invisibly
                                or not at all.
    4. `deep_nest.json`       — 400 levels of nesting on few lines: structure
                                that a line window cuts in the wrong place.
    5. `binary_adjacent.dat`  — text with NUL bytes and invalid UTF-8 partway
                                in, so a head sniff says "text" and the tail
                                disagrees.
    6. `base64_blob.txt`      — three 200 KB base64 lines: content that is
                                *legitimately* opaque, where clamping destroys
                                the only thing that made it useful.
    7. `growing.log`          — appended to BETWEEN reads. The one file where
                                answering "unchanged" would be a lie.
    8. `stable_config.yaml`   — small and re-read byte-identically, repeatedly.
                                The case redundant-read suppression exists for.
    9. `window_exact.txt`     — exactly as many lines as the read window asks
                                for, so "the window filled up" and "the file
                                ended" are indistinguishable without a stamp.

  ## Determinism

  Content is generated from a fixed seed and fixed formulas, never from
  `:rand` without seeding and never from anything on the host. Two runs on two
  machines produce byte-identical files, because an ablation whose inputs move
  measures nothing. `build/1` is idempotent: it wipes and rewrites the
  directory, so a re-run is never contaminated by a previous one's mutations
  (`growing.log` in particular is mutated by the scenarios that use it).
  """

  @doc "Every file name in the corpus, in a stable order."
  @spec names() :: [String.t()]
  def names do
    [
      "huge_flat.txt",
      "minified.js",
      "mixed_widths.log",
      "deep_nest.json",
      "binary_adjacent.dat",
      "base64_blob.txt",
      "growing.log",
      "stable_config.yaml",
      "window_exact.txt"
    ]
  end

  @doc """
  How many lines `window_exact.txt` has. Scenarios read exactly this many, so
  the number has to be shared rather than duplicated at the call site — a drift
  of one between corpus and scenario would silently turn the EOF case into the
  continuation case and the result would still look plausible.
  """
  @spec exact_window() :: pos_integer()
  def exact_window, do: 200

  @doc """
  Write the corpus into `dir` (created, and wiped first). Returns `dir`.
  """
  @spec build(Path.t()) :: Path.t()
  def build(dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    Enum.each(names(), fn name -> File.write!(Path.join(dir, name), content(name)) end)

    dir
  end

  @doc "The exact bytes of one corpus file."
  @spec content(String.t()) :: binary()
  def content("huge_flat.txt") do
    # 60_000 lines of plausible-looking log text. Line N states its own number,
    # so a probe can verify that a window landed where it claimed to.
    1..60_000
    |> Enum.map_join("\n", fn n ->
      "line #{n} | evt=#{rem(n * 7919, 1000)} | payload=#{String.duplicate("x", rem(n, 40))}"
    end)
    |> Kernel.<>("\n")
  end

  def content("minified.js") do
    # One line, ~900 KB. Deliberately no newline until the very end: this is the
    # shape where `limit: 1` is not a small read.
    body =
      1..30_000
      |> Enum.map_join(";", fn n -> "function f#{n}(a,b){return a*#{n}+b}" end)

    "(function(){" <> body <> ";window.SENTINEL_MINIFIED=1})();\n"
  end

  def content("mixed_widths.log") do
    # 5_000 ordinary lines with three 50 KB monsters buried at 1_000 / 2_500 /
    # 4_100. A cap that only ever sees uniform files would never meet this.
    1..5_000
    |> Enum.map_join("\n", fn
      n when n in [1_000, 2_500, 4_100] ->
        "BIG#{n} " <> String.duplicate("A", 50_000) <> " END#{n}"

      n ->
        "ok #{n} status=#{rem(n, 7)}"
    end)
    |> Kernel.<>("\n")
  end

  def content("deep_nest.json") do
    # 400 levels deep but only a handful of lines, so a line-addressed window
    # cannot help but cut the structure somewhere meaningless.
    open = String.duplicate(~s({"k":), 400)
    close = String.duplicate("}", 400)
    ~s({"depth":400,"tree":) <> open <> ~s("LEAF_SENTINEL") <> close <> "}\n"
  end

  def content("binary_adjacent.dat") do
    # The head is clean ASCII — a 4 KB sniff says "text". Then NULs and an
    # invalid UTF-8 continuation byte, which is exactly the case where a tool
    # that trusts its sniff emits mojibake into the transcript.
    head = String.duplicate("readable header line\n", 300)
    dirty = <<0, 1, 2, 255, 254, 0, 0>> <> "tail after nulls\n" <> <<0xC3, 0x28>>
    head <> dirty <> String.duplicate("more text\n", 100)
  end

  def content("base64_blob.txt") do
    # Opaque by nature: truncating a base64 line does not degrade it, it
    # destroys it. The counterweight to `minified.js` in the clamp ablation.
    blob = :binary.copy("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5", 4_200)

    Enum.map_join(1..3, "\n", fn n -> "blob#{n}=#{blob}" end) <> "\n"
  end

  def content("growing.log") do
    # Starts small. Scenarios append to it between reads; `append/2` below is
    # the only sanctioned way to do that.
    Enum.map_join(1..40, "\n", fn n -> "entry #{n}" end) <> "\n"
  end

  def content("stable_config.yaml") do
    """
    service: osa
    replicas: 3
    limits:
      memory: 2Gi
      cpu: "1500m"
    features:
      - ablation
      - stamps
      - clamp
    SENTINEL_CONFIG: stable
    """
  end

  def content("window_exact.txt") do
    # Exactly `exact_window/0` lines. A read of that many lines consumes the
    # whole file, and content alone cannot say so.
    Enum.map_join(1..exact_window(), "\n", fn n -> "row #{n}" end) <> "\n"
  end

  @doc """
  Append to `growing.log`, the one corpus file that legitimately changes.

  Separate from `build/1` because the point of the file is what happens BETWEEN
  two reads, which no static fixture can express.
  """
  @spec append(Path.t(), pos_integer()) :: :ok
  def append(dir, n) do
    File.write!(
      Path.join(dir, "growing.log"),
      Enum.map_join(1..n, "\n", fn i -> "appended #{i}" end) <> "\n",
      [:append]
    )
  end
end
