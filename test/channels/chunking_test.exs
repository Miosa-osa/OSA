defmodule OptimalSystemAgent.Channels.ChunkingTest do
  @moduledoc """
  Regression tests for the messaging-channel defects that silently dropped
  parts of a reply.

  ## Why every payload here is multi-byte

  The chunking bug only exists when bytes, UTF-16 code units and graphemes
  disagree. An ASCII test proves nothing: for ASCII all three measures are equal,
  so the old `byte_size/1`-tests-but-`String.split_at/2`-splits code produced
  correct output. These tests therefore use real payloads whose measures diverge:

    * CJK — 3 bytes, 1 UTF-16 unit, 1 grapheme per char (3x byte/unit divergence)
    * astral emoji — 4 bytes, 2 units, 1 grapheme
    * ZWJ family sequence — 25 bytes, 11 units, 1 grapheme (25x divergence)
    * regional-indicator flag — 8 bytes, 4 units, 1 grapheme
    * emoji + skin-tone modifier — 8 bytes, 4 units, 1 grapheme
    * base + combining mark — 3 bytes, 2 units, 1 grapheme

  Every chunk assertion measures the chunk the way that provider measures it,
  using the channel module's own declared limit and unit rather than a copy.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.Chunker
  alias OptimalSystemAgent.Channels.Delivery

  # ── Real multi-byte payloads ────────────────────────────────────────────

  # "The quick brown fox jumps over the lazy dog" in Chinese, plus Japanese
  # kana and Korean hangul. 3 UTF-8 bytes each, 1 UTF-16 unit each.
  @cjk "敏捷的棕色狐狸跳过了那只懒狗。日本語のテキストもここにあります。한국어 텍스트도 여기 있습니다。"

  # Man + ZWJ + Woman + ZWJ + Girl + ZWJ + Boy. One extended grapheme cluster.
  @zwj_family "👨‍👩‍👧‍👦"

  # Flag of Japan: two regional indicator symbols. One grapheme cluster.
  @flag "🇯🇵"

  # Thumbs up + medium skin tone modifier. One grapheme cluster.
  @skin_tone "👍🏽"

  # "e" + U+0301 COMBINING ACUTE ACCENT — decomposed, so 2 codepoints that must
  # never be torn apart.
  @combining "é"

  # Plain astral emoji (outside the BMP, so 2 UTF-16 units each).
  @emoji "🚀🔥🎉🌍🧪"

  @mixed @cjk <> @zwj_family <> @flag <> @skin_tone <> @combining <> @emoji

  # Every channel that chunks outbound text, paired with nothing but its own
  # declared limit — the test never hardcodes a limit of its own.
  @channels [
    OptimalSystemAgent.Channels.Telegram,
    OptimalSystemAgent.Channels.Slack,
    OptimalSystemAgent.Channels.Discord,
    OptimalSystemAgent.Channels.Line,
    OptimalSystemAgent.Channels.Signal,
    OptimalSystemAgent.Channels.Matrix,
    OptimalSystemAgent.Channels.WhatsApp,
    OptimalSystemAgent.Channels.WeCom,
    OptimalSystemAgent.Channels.DingTalk,
    OptimalSystemAgent.Channels.Feishu
  ]

  # ── The divergence the bug depended on ──────────────────────────────────

  describe "Chunker.measure/2 — bytes, UTF-16 units and graphemes really do diverge" do
    test "a ZWJ family sequence is 1 grapheme, 11 UTF-16 units and 25 bytes" do
      assert Chunker.measure(@zwj_family, :graphemes) == 1
      assert Chunker.measure(@zwj_family, :utf16) == 11
      assert Chunker.measure(@zwj_family, :bytes) == 25
    end

    test "a CJK character is 1 grapheme, 1 UTF-16 unit and 3 bytes" do
      assert Chunker.measure("漢", :graphemes) == 1
      assert Chunker.measure("漢", :utf16) == 1
      assert Chunker.measure("漢", :bytes) == 3
    end

    test "an astral emoji is 1 grapheme, 2 UTF-16 units and 4 bytes" do
      assert Chunker.measure("🚀", :graphemes) == 1
      assert Chunker.measure("🚀", :utf16) == 2
      assert Chunker.measure("🚀", :bytes) == 4
    end

    test "a regional-indicator flag is 1 grapheme, 4 UTF-16 units and 8 bytes" do
      assert Chunker.measure(@flag, :graphemes) == 1
      assert Chunker.measure(@flag, :utf16) == 4
      assert Chunker.measure(@flag, :bytes) == 8
    end

    test "an emoji with a skin-tone modifier is 1 grapheme, 4 UTF-16 units and 8 bytes" do
      assert Chunker.measure(@skin_tone, :graphemes) == 1
      assert Chunker.measure(@skin_tone, :utf16) == 4
      assert Chunker.measure(@skin_tone, :bytes) == 8
    end

    test "a base+combining-mark pair is 1 grapheme, 2 UTF-16 units and 3 bytes" do
      assert Chunker.measure(@combining, :graphemes) == 1
      assert Chunker.measure(@combining, :utf16) == 2
      assert Chunker.measure(@combining, :bytes) == 3
    end

    test "ASCII is the one case where all three agree — which is why ASCII tests miss the bug" do
      ascii = "the quick brown fox"
      assert Chunker.measure(ascii, :bytes) == 19
      assert Chunker.measure(ascii, :utf16) == 19
      assert Chunker.measure(ascii, :graphemes) == 19
    end
  end

  # ── Defect 1: the hole in the middle of the reply ───────────────────────

  describe "Defect 1 — measuring in one unit and splitting in another" do
    test "the old telegram/slack/discord algorithm really did emit an over-limit chunk" do
      # This reproduces the shipped code verbatim at a small limit so the
      # arithmetic is easy to see: test with byte_size/1, cut with
      # String.split_at/2.
      limit = 100
      para = String.duplicate("🚀", 500)

      assert byte_size(para) > limit, "precondition: the byte test must trip"
      {head, _tail} = String.split_at(para, limit - 10)

      # The cut returned 90 graphemes. Measured the way Discord and Telegram
      # actually measure — UTF-16 code units — that is 180, nearly 2x a limit
      # the code believed it had just enforced.
      assert Chunker.measure(head, :utf16) == 180
      assert Chunker.measure(head, :utf16) > limit

      # The new chunker, given the same limit and the unit the provider counts,
      # never does this.
      for chunk <- Chunker.chunk(para, limit, :utf16) do
        assert Chunker.measure(chunk, :utf16) <= limit
      end
    end

    test "byte-capped providers were broken by CJK, which the old code measured as graphemes" do
      limit = 100
      para = String.duplicate("漢", 200)

      # The five grapheme-counting adapters (matrix/whatsapp/wecom/dingtalk/
      # feishu) chunked with Enum.chunk_every(graphemes, limit), producing
      # `limit` graphemes per chunk...
      old_chunk = para |> String.graphemes() |> Enum.chunk_every(limit) |> hd() |> Enum.join()

      # ...which is 3x over a byte-denominated cap.
      assert Chunker.measure(old_chunk, :bytes) == 300
      assert Chunker.measure(old_chunk, :bytes) > limit

      for chunk <- Chunker.chunk(para, limit, :bytes) do
        assert Chunker.measure(chunk, :bytes) <= limit
      end
    end

    for channel <- @channels do
      test "#{inspect(channel)} keeps every chunk within its own limit, measured its own way" do
        channel = unquote(channel)
        {limit, unit} = channel.message_limit()

        # Roughly 8x the channel's limit, so the paragraph path and the
        # hard-split path are both exercised.
        payload = grow(@mixed, limit * 8, unit)
        chunks = channel.chunk_message(payload)

        assert length(chunks) > 1, "payload must be big enough to force a split"

        for {chunk, index} <- Enum.with_index(chunks, 1) do
          assert Chunker.measure(chunk, unit) <= limit,
                 "chunk #{index}/#{length(chunks)} is #{Chunker.measure(chunk, unit)} #{unit}, " <>
                   "over #{inspect(channel)}'s limit of #{limit}"
        end
      end

      test "#{inspect(channel)} loses no content — no hole anywhere in the reply" do
        channel = unquote(channel)
        {limit, unit} = channel.message_limit()

        payload = grow(@mixed, limit * 8, unit)
        chunks = channel.chunk_message(payload)

        assert strip_ws(Enum.join(chunks)) == strip_ws(payload)
      end

      test "#{inspect(channel)} never tears a grapheme cluster in half" do
        channel = unquote(channel)
        {limit, unit} = channel.message_limit()

        # A wall of nothing but ZWJ families, flags, skin tones and combining
        # marks, with no whitespace anywhere — so it is one single paragraph and
        # the only code path available is the grapheme-safe hard split. If the
        # splitter ever cuts inside a cluster the chunk boundary yields
        # graphemes that are not in the original, and this exact comparison
        # catches it.
        clusters = @zwj_family <> @flag <> @skin_tone <> @combining
        payload = grow_dense(clusters, limit * 4, unit)
        chunks = channel.chunk_message(payload)

        refute payload =~ ~r/\s/u, "payload must be a single whitespace-free paragraph"
        assert Enum.join(chunks) == payload
        assert String.graphemes(Enum.join(chunks)) == String.graphemes(payload)
      end
    end

    test "a paragraph-shaped reply still splits on paragraph boundaries" do
      paragraph = String.duplicate(@cjk, 10)
      text = Enum.map_join(1..20, "\n\n", fn _ -> paragraph end)

      chunks = Chunker.chunk(text, 4_000, :bytes)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(Chunker.measure(&1, :bytes) <= 4_000))
      assert strip_ws(Enum.join(chunks)) == strip_ws(text)
    end

    test "text that already fits is returned untouched" do
      assert Chunker.chunk(@mixed, 10_000, :bytes) == [@mixed]
    end

    test "a single grapheme cluster wider than the limit is emitted whole, not looped on" do
      # The ZWJ family is 25 bytes; a 5-byte limit cannot hold it. Splitting it
      # would mangle it, so it goes out intact rather than hanging the splitter.
      chunks = Chunker.chunk(@zwj_family <> @zwj_family, 5, :bytes)

      assert chunks == [@zwj_family, @zwj_family]
    end

    test "no empty or whitespace-only chunk is ever produced" do
      text = String.duplicate(@cjk <> "\n\n\n\n", 50)

      for chunk <- Chunker.chunk(text, 200, :bytes) do
        refute String.trim(chunk) == ""
      end
    end
  end

  # ── Defect 2: LINE dropped chunks 6+ ────────────────────────────────────

  describe "Defect 2 — LINE's Enum.take(5)" do
    alias OptimalSystemAgent.Channels.Line

    setup do
      {limit, unit} = Line.message_limit()
      # Big enough to need well over 5 chunks — the range the old code discarded.
      payload = grow(@mixed, limit * 12, unit)
      chunks = Line.chunk_message(payload)

      assert length(chunks) > Line.max_messages_per_request(),
             "payload must exceed LINE's 5-messages-per-request cap"

      %{payload: payload, chunks: chunks, limit: limit, unit: unit}
    end

    test "the old code discarded everything past chunk 5", %{chunks: chunks} do
      kept = Enum.take(chunks, 5)
      dropped = length(chunks) - length(kept)

      assert dropped > 0
      refute strip_ws(Enum.join(kept)) == strip_ws(Enum.join(chunks))
    end

    test "every chunk now survives batching — nothing is dropped", %{
      payload: payload,
      chunks: chunks
    } do
      batched = Line.batches(payload)

      assert List.flatten(batched) == chunks
      assert strip_ws(batched |> List.flatten() |> Enum.join()) == strip_ws(payload)
    end

    test "each batch respects LINE's 5-messages-per-request cap", %{payload: payload} do
      for batch <- Line.batches(payload) do
        assert length(batch) <= Line.max_messages_per_request()
        assert batch != []
      end
    end

    test "when overflow genuinely cannot be delivered it is announced, not dropped", %{
      payload: payload,
      limit: limit,
      unit: unit
    } do
      [first | rest] = Line.batches(payload)
      undeliverable = rest |> List.flatten() |> length()

      marked = Line.mark_truncated(first, undeliverable)

      # Still a legal request: 5 messages, each within LINE's per-message limit.
      assert length(marked) == length(first)
      assert Enum.all?(marked, &(Chunker.measure(&1, unit) <= limit))

      # And the user is told, in the delivered message, exactly what is missing.
      notice = List.last(marked)
      assert notice =~ "#{undeliverable} further message(s) could not be delivered"
    end
  end

  # ── Defect 3: Signal did no chunking at all ─────────────────────────────

  describe "Defect 3 — Signal sent the whole reply in one body" do
    alias OptimalSystemAgent.Channels.Signal

    test "a long reply is now split, and every piece fits Signal's byte budget" do
      {limit, unit} = Signal.message_limit()
      assert unit == :bytes

      payload = grow(@mixed, limit * 6, unit)
      chunks = Signal.chunk_message(payload)

      assert length(chunks) > 1, "Signal used to return this as a single over-long body"
      assert Enum.all?(chunks, &(Chunker.measure(&1, :bytes) <= limit))
      assert strip_ws(Enum.join(chunks)) == strip_ws(payload)
    end
  end

  # ── Defect 4: :ok returned regardless of per-chunk failures ─────────────

  describe "Defect 4 — a failed send must not report :ok" do
    test "all chunks accepted returns :ok" do
      assert Delivery.send_chunks(:test, ["a", "b", "c"], fn _ -> :ok end) == :ok
    end

    test "a mid-reply failure does not return :ok" do
      result =
        Delivery.send_chunks(:test, ["a", "b", "c", "d"], fn
          "c" -> {:error, :rejected}
          _ -> :ok
        end)

      refute result == :ok
      assert {:error, {:chunk_failed, 3, 4, :rejected}} = result
    end

    test "the error says how much of the reply actually landed" do
      assert {:error, {:chunk_failed, index, total, _}} =
               Delivery.send_chunks(:test, ~w(a b c d e), fn
                 "d" -> {:error, :http_400}
                 _ -> :ok
               end)

      assert index == 4
      assert total == 5
    end

    test "delivery halts at the break instead of punching a hole and carrying on" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      Delivery.send_chunks(:test, ~w(a b c d e), fn chunk ->
        Agent.update(agent, &[chunk | &1])
        if chunk == "c", do: {:error, :rejected}, else: :ok
      end)

      # d and e were never posted: a short reply, not one with a gap in it.
      assert Agent.get(agent, &Enum.reverse/1) == ~w(a b c)
    end

    test "a first-chunk failure does not return :ok" do
      refute Delivery.send_chunks(:test, ["a"], fn _ -> {:error, :nope} end) == :ok
    end

    test "post functions that answer {:ok, _} count as success" do
      assert Delivery.send_chunks(:test, ["a", "b"], fn _ -> {:ok, %{status: 200}} end) == :ok
    end

    test "an empty chunk list is trivially :ok" do
      assert Delivery.send_chunks(:test, [], fn _ -> {:error, :never_called} end) == :ok
    end
  end

  # ── Defect 5: {:error, :max_children} was ignored ───────────────────────

  describe "Defect 5 — a saturated task pool must not fail silently" do
    test "start_task surfaces {:error, :max_children} instead of discarding it" do
      {:ok, sup} = Task.Supervisor.start_link(max_children: 1)

      # Occupy the only slot.
      assert {:ok, _pid} = Delivery.start_task(:test, fn -> Process.sleep(5_000) end, sup)

      # The second turn cannot start. The old code threw this return away, so
      # the user waited forever for a reply that was never queued.
      assert {:error, :max_children} = Delivery.start_task(:test, fn -> :ok end, sup)
    end

    test "start_task returns {:ok, pid} when the pool has room" do
      {:ok, sup} = Task.Supervisor.start_link(max_children: 4)
      assert {:ok, pid} = Delivery.start_task(:test, fn -> :ok end, sup)
      assert is_pid(pid)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Repeats `seed` (with paragraph breaks) until it measures at least `target`
  # in `unit`.
  defp grow(seed, target, unit) do
    Enum.map_join(1..reps(seed, target, unit), "\n\n", fn _ -> seed end)
  end

  # Same, but with no separators at all: one very long paragraph containing no
  # whitespace, which forces the hard-split path and allows exact comparison.
  defp grow_dense(seed, target, unit) do
    String.duplicate(seed, reps(seed, target, unit))
  end

  defp reps(seed, target, unit) do
    ceil(target / max(Chunker.measure(seed, unit), 1)) + 1
  end

  defp strip_ws(text), do: String.replace(text, ~r/\s/u, "")
end
