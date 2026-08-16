defmodule OptimalSystemAgent.Tools.FileReadByteRangeTest do
  @moduledoc """
  A clamped line's tail must be reachable.

  `mix osa.ablate` measured three facts that the per-line clamp destroyed
  PERMANENTLY — the end of a minified file, a base64 blob's decodability, a deep
  JSON leaf. Not expensive: unreachable. `offset`/`limit` address lines, and the
  line in question was already fully selected, so no subsequent call in any tool
  could ask for the rest of it.

  The ablation is the acceptance test for the capability; this file pins the
  contract the ablation depends on, so a change that keeps the harness green by
  accident still fails here.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Constants
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-byte-range-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok,
     dir: dir, ctx: %UseContext{session_id: "byte-range-#{System.unique_integer([:positive])}"}}
  end

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp read(path, ctx, input \\ %{}) do
    {:ok, text} = Handler.execute(Map.put(input, "path", path), ctx)
    text
  end

  # ── The recovery path ─────────────────────────────────────────────────────

  describe "the clamp notice names a byte_offset that works" do
    test "the offset in the marker is exactly where the shown text stopped", %{
      dir: dir,
      ctx: ctx
    } do
      cap = Constants.max_line_chars()
      line = String.duplicate("a", cap) <> "TAIL_SENTINEL" <> String.duplicate("b", 500)
      path = write(dir, "one_line.txt", line <> "\n")

      clamped = read(path, ctx)

      assert [_, offset] = Regex.run(~r/byte_offset: (\d+)/, clamped)
      offset = String.to_integer(offset)

      assert offset == cap,
             "an ASCII line's clamp stops at byte #{cap}; the marker said #{offset}"

      rest = read(path, ctx, %{"byte_offset" => offset})

      assert String.starts_with?(rest, "TAIL_SENTINEL"),
             "the resume offset must land on the first byte the clamp did NOT show"
    end

    test "the resume offset is byte-correct for a multi-byte line", %{dir: dir, ctx: ctx} do
      # The cap counts characters, `byte_offset` counts bytes. Assuming they are
      # the same number lands mid-codepoint and hands back a replacement
      # character where real content should start.
      cap = Constants.max_line_chars()
      line = String.duplicate("é", cap) <> "MULTIBYTE_SENTINEL"
      path = write(dir, "wide.txt", line <> "\n")

      clamped = read(path, ctx)
      [_, offset] = Regex.run(~r/byte_offset: (\d+)/, clamped)
      offset = String.to_integer(offset)

      assert offset == cap * 2, "é is two bytes; the resume point must be measured in bytes"

      rest = read(path, ctx, %{"byte_offset" => offset})
      assert String.starts_with?(rest, "MULTIBYTE_SENTINEL")
      refute String.contains?(rest, "�"), "a correct resume point never splits a character"
    end

    test "a line beyond the FIRST one gets a correct offset too", %{dir: dir, ctx: ctx} do
      cap = Constants.max_line_chars()
      long = String.duplicate("x", cap) <> "SECOND_LINE_TAIL"
      path = write(dir, "two.txt", "header line\n" <> long <> "\n")

      clamped = read(path, ctx)
      [_, offset] = Regex.run(~r/byte_offset: (\d+)/, clamped)

      rest = read(path, ctx, %{"byte_offset" => String.to_integer(offset)})
      assert String.starts_with?(rest, "SECOND_LINE_TAIL")
    end

    test "the same holds through a windowed (offset/limit) read", %{dir: dir, ctx: ctx} do
      cap = Constants.max_line_chars()
      long = String.duplicate("y", cap) <> "WINDOWED_TAIL"

      path =
        write(dir, "windowed.txt", Enum.map_join(1..9, "", &"pad #{&1}\n") <> long <> "\n")

      clamped = read(path, ctx, %{"offset" => 10, "limit" => 1})
      [_, offset] = Regex.run(~r/byte_offset: (\d+)/, clamped)

      rest = read(path, ctx, %{"byte_offset" => String.to_integer(offset)})

      assert String.starts_with?(rest, "WINDOWED_TAIL"),
             "the windowed path streams past the dropped lines; it must still count their bytes"
    end
  end

  # ── Byte-range semantics ──────────────────────────────────────────────────

  describe "byte_offset addressing" do
    test "a negative offset reads the tail", %{dir: dir, ctx: ctx} do
      path = write(dir, "tail.txt", String.duplicate("z", 5_000) <> "THE_VERY_END")

      out = read(path, ctx, %{"byte_offset" => -12})

      assert String.starts_with?(out, "THE_VERY_END")
      assert out =~ "end of file"
    end

    test "a negative offset larger than the file reads the whole file", %{dir: dir, ctx: ctx} do
      path = write(dir, "small.txt", "tiny")
      out = read(path, ctx, %{"byte_offset" => -999_999})
      assert out =~ "tiny"
    end

    test "the stamp names the next offset, and the walk tiles the file", %{dir: dir, ctx: ctx} do
      body = Enum.map_join(1..3_000, "", fn n -> "#{rem(n, 10)}" end)
      path = write(dir, "walk.txt", body)

      first = read(path, ctx, %{"byte_offset" => 0, "byte_limit" => 1_000})
      assert [_, next] = Regex.run(~r/byte_offset=(\d+)/, first)
      assert String.to_integer(next) == 1_000

      second = read(path, ctx, %{"byte_offset" => 1_000, "byte_limit" => 1_000})

      # Strip the stamps and check the two slices join back into the original —
      # a walk that overlaps or skips is worse than no walk, because the caller
      # cannot tell.
      joined = strip_stamp(first) <> strip_stamp(second)
      assert joined == binary_part(body, 0, 2_000)
    end

    test "byte_limit is clamped to the ceiling rather than honoured blindly", %{
      dir: dir,
      ctx: ctx
    } do
      path = write(dir, "big.txt", String.duplicate("q", 100_000))
      out = read(path, ctx, %{"byte_offset" => 0, "byte_limit" => 999_999_999})

      assert byte_size(strip_stamp(out)) == Constants.max_byte_slice()
    end

    test "an offset past the end says how big the file is", %{dir: dir, ctx: ctx} do
      path = write(dir, "short.txt", "0123456789")
      assert {:error, msg} = Handler.execute(%{"path" => path, "byte_offset" => 99}, ctx)

      assert msg =~ "10"
      assert msg =~ "byte_offset"
    end

    test "a non-integer byte_offset is rejected at validation", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"path" => "/tmp/x", "byte_offset" => "500"}, ctx)

      assert msg =~ "byte_offset"
    end
  end

  # ── Interactions that would silently break the recovery ───────────────────

  describe "the recovery call is not swallowed by another feature" do
    test "redundant-read suppression does not answer a byte read with 'unchanged'", %{
      dir: dir,
      ctx: ctx
    } do
      # The byte read that recovers a clamped tail almost always follows the
      # whole-file read that clamped it, in the same session. A range key that
      # ignored the byte axis would hash both to `:whole` and answer the second
      # with "unchanged since your last read" — true, useless, and exactly the
      # dead end this capability exists to remove.
      cap = Constants.max_line_chars()
      path = write(dir, "reread.txt", String.duplicate("w", cap) <> "RECOVERED_TAIL\n")

      _first = read(path, ctx)
      rest = read(path, ctx, %{"byte_offset" => cap})

      assert String.starts_with?(rest, "RECOVERED_TAIL")
      refute rest =~ ~r/unchanged/i
    end

    test "a byte read works on a file the whole-file path refuses as binary", %{
      dir: dir,
      ctx: ctx
    } do
      path = write(dir, "bin.dat", <<0, 1, 2, 255>> <> "PAST_THE_NULS")

      assert {:error, _} = Handler.execute(%{"path" => path}, ctx)

      out = read(path, ctx, %{"byte_offset" => 4})

      assert out =~ "PAST_THE_NULS",
             "refusing a byte range because the file looks binary is a dead end — the caller " <>
               "already said it wants raw bytes at a raw position"
    end

    test "an invalid-UTF-8 slice is scrubbed and labelled, never sent raw", %{
      dir: dir,
      ctx: ctx
    } do
      path = write(dir, "cut.txt", "aaa" <> <<0xC3>> <> <<0x28>> <> "bbb")
      out = read(path, ctx, %{"byte_offset" => 0})

      assert String.valid?(out), "an invalid byte on the wire ends the turn at the provider"
      assert out =~ "byte window"
    end

    test "a byte read is still recorded for read-before-edit", %{dir: dir, ctx: ctx} do
      path = write(dir, "edited.txt", String.duplicate("m", 100))
      _ = read(path, ctx, %{"byte_offset" => 0})

      assert OptimalSystemAgent.Tools.FileState.read_status(
               ctx.session_id,
               path,
               {{:bytes, 0}, nil}
             ) != :never_read
    end
  end

  defp strip_stamp(text), do: Regex.replace(~r/\n\(Bytes .*?\)$/s, text, "")
end
