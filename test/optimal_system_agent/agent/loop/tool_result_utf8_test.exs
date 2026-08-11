defmodule OptimalSystemAgent.Agent.Loop.ToolResultUtf8Test do
  @moduledoc """
  Byte-boundary safety on the path from a tool result to the provider.

  `ToolResultStorage.apply_budget/4` builds the preview that is sent to the
  model. Its byte-based head+tail fallback cut the binary with `binary_part/3`
  at two arbitrary offsets. The TAIL is the dangerous one — it starts at
  `total - tail_bytes`, which lands mid-sequence on almost any multibyte
  content — and the fallback is reached by any result over the byte threshold
  whose line count is too low to slice by line: minified JSON, a base64 blob,
  a CJK or emoji log.

  That matters because the request body is serialized with
  `Jason.encode_to_iodata!/1`, which RAISES on invalid UTF-8. So the outcome is
  a killed turn, not a garbled character. `ShellExecute.Handler` already scrubs
  its output to valid UTF-8 — `apply_budget/4` ran afterwards and re-broke it.

  Separately, the disk-write fallback paths sliced with `String.slice/3` while
  the surrounding message claimed "first N bytes". `String.slice/3` counts
  GRAPHEMES, so the same threshold emitted roughly 3x on CJK and 4x on
  4-byte emoji.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage
  alias OptimalSystemAgent.Utils.Text

  @threshold 51_200

  setup do
    prev = Application.get_env(:optimal_system_agent, :max_tool_output_bytes)

    on_exit(fn ->
      if is_nil(prev) do
        Application.delete_env(:optimal_system_agent, :max_tool_output_bytes)
      else
        Application.put_env(:optimal_system_agent, :max_tool_output_bytes, prev)
      end
    end)

    :ok
  end

  # A single-line blob well over the byte threshold and under the line
  # threshold — exactly the shape that reaches the byte head+tail fallback.
  defp big_single_line(unit) do
    String.duplicate(unit, div(@threshold * 3, byte_size(unit)) + 1)
  end

  defp budget(str),
    do: ToolResultStorage.apply_budget(str, "shell_execute", "tc-utf8", "sess-utf8")

  describe "the preview handed to the provider is always encodable" do
    for {label, unit} <- [
          {"CJK", "中文日本語한국어"},
          {"emoji", "😀🎉🚀🔥"},
          {"accented Latin", "éàüöñçß"},
          {"mixed ASCII and multibyte", "abc中def😀ghi"},
          {"minified JSON with multibyte values", ~s({"k":"日本語テキスト","n":1234},)}
        ] do
      test "#{label} content survives the byte budget and JSON-encodes" do
        out = budget(big_single_line(unquote(unit)))

        assert String.valid?(out),
               "the preview contains invalid UTF-8 — Jason.encode_to_iodata!/1 will raise on it"

        # The actual failure mode, exercised directly: this is what
        # Anthropic.build_body/Jason does with the tool result.
        assert is_binary(IO.iodata_to_binary(Jason.encode_to_iodata!(%{"content" => out})))
      end
    end

    # Whether an UNGUARDED byte cut lands mid-character depends on how the
    # content happens to align with the fixed head/tail offsets, so a single
    # fixture proves little. Shifting the payload by 0-3 leading ASCII bytes
    # walks the cut through every position within a multibyte character, which
    # makes at least one variant per unit land mid-sequence for certain.
    for {label, unit} <- [
          {"CJK", "中文日本語한국어"},
          {"emoji", "😀🎉🚀🔥"},
          {"accented Latin", "éàüöñçß"}
        ],
        pad <- 0..3 do
      test "#{label} content stays encodable at byte alignment +#{pad}" do
        out = budget(String.duplicate("x", unquote(pad)) <> big_single_line(unquote(unit)))

        assert String.valid?(out),
               "alignment +#{unquote(pad)} produced invalid UTF-8"

        assert is_binary(IO.iodata_to_binary(Jason.encode_to_iodata!(%{"content" => out})))
      end
    end

    test "content that was ALREADY invalid UTF-8 does not become unencodable" do
      # A tool that did not scrub its own output. The budget must not be the
      # thing that turns it into a raise.
      blob = String.duplicate(<<0xFF, 0xFE, "some text ">>, 6_000)
      refute String.valid?(blob)

      out = budget(blob)
      assert String.valid?(out)
      assert is_binary(IO.iodata_to_binary(Jason.encode_to_iodata!(%{"content" => out})))
    end

    test "the preview is genuinely smaller than the input" do
      input = big_single_line("中文日本語한국어")
      out = budget(input)
      assert byte_size(out) < byte_size(input)
    end
  end

  describe "Utils.Text byte-bounded slicing" do
    test "utf8_head never exceeds the byte budget" do
      s = String.duplicate("日", 100)

      for n <- 0..40 do
        head = Text.utf8_head(s, n)
        assert byte_size(head) <= n
        assert String.valid?(head)
      end
    end

    test "utf8_tail never exceeds the byte budget" do
      s = String.duplicate("日", 100)

      for n <- 0..40 do
        tail = Text.utf8_tail(s, n)
        assert byte_size(tail) <= n
        assert String.valid?(tail)
      end
    end

    test "utf8_head/utf8_tail are exact when the cut lands on a boundary" do
      s = "日本語"
      assert Text.utf8_head(s, 3) == "日"
      assert Text.utf8_head(s, 6) == "日本"
      assert Text.utf8_tail(s, 3) == "語"
      assert Text.utf8_tail(s, 6) == "本語"
    end

    test "utf8_head/utf8_tail trim to the boundary when the cut lands inside a character" do
      s = "日本語"
      # 4 bytes = one full 3-byte char plus one stray byte.
      assert Text.utf8_head(s, 4) == "日"
      assert Text.utf8_head(s, 5) == "日"
      # A tail cut at 4 bytes orphans two continuation bytes of "本".
      assert Text.utf8_tail(s, 4) == "語"
      assert Text.utf8_tail(s, 5) == "語"
    end

    test "a 4-byte character is handled at every offset" do
      s = "a😀b"

      for n <- 0..byte_size(s) do
        assert String.valid?(Text.utf8_head(s, n))
        assert String.valid?(Text.utf8_tail(s, n))
      end
    end

    test "the whole binary is returned when it fits" do
      assert Text.utf8_head("日本語", 100) == "日本語"
      assert Text.utf8_tail("日本語", 100) == "日本語"
    end

    test "scrub_utf8 preserves length rather than truncating at the first bad byte" do
      out = Text.scrub_utf8(<<"good ", 0xFF, " tail">>)
      assert String.valid?(out)
      assert String.contains?(out, "good ")
      assert String.contains?(out, " tail"), "the tail after a bad byte must not be discarded"
    end

    test "valid input is returned untouched" do
      assert Text.scrub_utf8("日本語 ok") == "日本語 ok"
    end
  end

  describe "the byte threshold is measured in BYTES" do
    test "a CJK fallback slice respects the byte cap it advertises" do
      # String.slice/3 counts graphemes: asking it for 51_200 against 3-byte
      # characters returns ~150KB while the adjacent message says
      # "showing first 51200 bytes".
      s = String.duplicate("日", 40_000)
      head = Text.utf8_head(s, @threshold)

      assert byte_size(head) <= @threshold,
             "a byte-named budget emitted #{byte_size(head)} bytes for a #{@threshold} cap"
    end

    test "a 4-byte emoji fallback slice respects the byte cap" do
      s = String.duplicate("😀", 30_000)
      assert byte_size(Text.utf8_head(s, @threshold)) <= @threshold
    end
  end
end
