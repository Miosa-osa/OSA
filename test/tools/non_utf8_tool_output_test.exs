defmodule OptimalSystemAgent.Tools.NonUtf8ToolOutputTest do
  @moduledoc """
  A tool result carrying non-UTF-8 bytes used to KILL THE TURN.

  Reproduced end to end before the fix, on a file containing a single latin-1
  byte (`0xDA`, `Ú`) — an entirely ordinary thing to find in a Python or C
  source file, a `.po` catalogue, or a fixture:

      file_grep → "…:401:x = \\"" <> <<0xDA>> <> "ltimo\\""
      Jason.encode_to_iodata!(%{messages: [%{content: that}]})
        ** (Jason.EncodeError) invalid byte 0xDA in <<…>>

  `Registry.do_apply_provider/3` rescues that raise into
  `{:error, "Provider error: invalid byte 0xDA …"}`, `ReactLoop` reports a
  failed LLM call, the turn ends, and the session produces a 0-byte patch.
  Because the failure surfaced as a provider error it was scored against the
  MODEL.

  These tests pin the tool-level half of the fix. The provider-boundary
  backstop is pinned in `test/providers/wire_encoding_backstop_test.exs`.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.CodebaseExplore
  alias OptimalSystemAgent.Tools.Builtins.FileGrep
  alias OptimalSystemAgent.Tools.Builtins.FileRead

  # 0xDA is `Ú` in latin-1/cp1252 and is not a legal standalone UTF-8 byte.
  @bad <<0xDA>>

  # Long enough that the bad byte lands well past `Constants.sniff_bytes/0`,
  # which is what made the whole-file binary guard miss it in the field.
  @ascii_padding String.duplicate("# padding line that is perfectly valid ascii\n", 400)

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_non_utf8_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp latin1_source(dir) do
    write(dir, "latin1.py", @ascii_padding <> "x = \"" <> @bad <> "ltimo\"\n")
  end

  # The single assertion that matters: whatever a tool returns must survive the
  # encoder that every provider request passes through.
  defp assert_encodable(result) do
    text =
      case result do
        {:ok, s} when is_binary(s) -> s
        {:error, s} when is_binary(s) -> s
        other -> flunk("expected a binary result, got: #{inspect(other)}")
      end

    assert String.valid?(text),
           "tool result is not valid UTF-8 — this is the byte sequence that kills the turn"

    assert Jason.encode_to_iodata!(%{messages: [%{role: "tool", content: text}]})
    text
  end

  # ── file_grep — the tool the failure was first observed in ──────────────

  describe "file_grep over a non-UTF-8 file" do
    test "returns valid UTF-8 that a provider request can encode", %{dir: dir} do
      latin1_source(dir)

      result = FileGrep.Handler.execute(%{"pattern" => "ltimo", "path" => dir}, ctx())
      text = assert_encodable(result)

      # The match is still THERE — scrubbed, not dropped. Losing the hit would
      # trade a dead turn for a silent wrong answer.
      assert text =~ "ltimo"
      assert text =~ "latin1.py"
    end

    test "tells the model the file is not UTF-8 instead of handing it mojibake", %{dir: dir} do
      latin1_source(dir)

      {:ok, text} = FileGrep.Handler.execute(%{"pattern" => "ltimo", "path" => dir}, ctx())

      assert text =~ "not valid UTF-8"
      assert text =~ "iconv", "the note must name the command that recovers the real characters"
      assert text =~ "�", "undecodable bytes are shown as U+FFFD, not deleted"
    end

    test "a plain ASCII result is byte-identical and carries no note", %{dir: dir} do
      write(dir, "clean.ex", "defmodule Foo do\n  def bar, do: :ok\nend\n")

      {:ok, text} = FileGrep.Handler.execute(%{"pattern" => "defmodule", "path" => dir}, ctx())

      assert text =~ "defmodule Foo"
      refute text =~ "not valid UTF-8"
      refute text =~ "�"
    end

    # The normal path must not be collateral damage. `String.slice/3` (the old
    # cap) counts graphemes, so this content was also mis-bounded before.
    test "valid UTF-8 with unusual codepoints is NOT mangled", %{dir: dir} do
      exotic = "naïve — 日本語 — 🙈🙉🙊 — Ω≈ç√ — á — ‍zwj"
      write(dir, "exotic.txt", "marker " <> exotic <> "\n")

      {:ok, text} = FileGrep.Handler.execute(%{"pattern" => "marker", "path" => dir}, ctx())

      assert text =~ exotic, "valid UTF-8 must survive byte-for-byte"
      refute text =~ "�"
      refute text =~ "not valid UTF-8"
    end

    test "empty and no-match results stay encodable", %{dir: dir} do
      write(dir, "empty.txt", "")

      assert_encodable(FileGrep.Handler.execute(%{"pattern" => "nothing", "path" => dir}, ctx()))
    end
  end

  # ── file_read ───────────────────────────────────────────────────────────

  describe "file_read over a non-UTF-8 file" do
    # Before the fix this raised `FunctionClauseError` out of
    # `Messages.binary/2`: `Magic.identify/1` returns the ATOM `:text` for an
    # ASCII-looking head, and the message function only matched the
    # `{:image, …}` / `{:binary, …}` tuples. A crash, not a tool error.
    test "whole-file read fails cleanly instead of raising", %{dir: dir} do
      path = latin1_source(dir)

      result =
        try do
          FileRead.Handler.execute(%{"path" => path}, ctx())
        rescue
          e -> flunk("file_read raised #{inspect(e.__struct__)} instead of returning an error")
        end

      assert {:error, message} = result
      text = assert_encodable(result)
      assert message == text
      assert text =~ "not valid UTF-8"
      assert text =~ "iconv"
    end

    # The `offset`/`limit` path had NO validity check at all — and it is the
    # path the tool's own "too large" message tells the caller to use.
    test "offset/limit slice returns scrubbed text, not raw bytes", %{dir: dir} do
      path = latin1_source(dir)

      result = FileRead.Handler.execute(%{"path" => path, "offset" => 399, "limit" => 5}, ctx())
      text = assert_encodable(result)

      assert text =~ "ltimo", "the requested slice is still returned"
      assert text =~ "�"
      assert text =~ "not valid UTF-8"
    end

    test "offset/limit over valid UTF-8 is unchanged", %{dir: dir} do
      path = write(dir, "ok.txt", "alpha\nbeta — β\ngamma 🙈\n")

      {:ok, text} =
        FileRead.Handler.execute(%{"path" => path, "offset" => 2, "limit" => 2}, ctx())

      assert text =~ "beta — β"
      assert text =~ "gamma 🙈"
      refute text =~ "�"
      refute text =~ "not valid UTF-8"
    end

    test "a genuinely binary file is summarised, not dumped", %{dir: dir} do
      # ELF header + NUL bytes: a compiled artifact, the case where returning
      # bytes at all is pointless as well as dangerous.
      path = write(dir, "a.out", <<0x7F, "ELF", 2, 1, 1, 0>> <> :binary.copy(<<0>>, 64) <> @bad)

      result = FileRead.Handler.execute(%{"path" => path}, ctx())
      text = assert_encodable(result)

      assert {:error, _} = result
      refute text =~ "�", "a binary is described, not transliterated"
      assert String.length(text) < 2_000, "the summary must be short — this is a token saving too"
    end

    test "an empty file is answered, not scrubbed into nonsense", %{dir: dir} do
      path = write(dir, "empty.txt", "")
      assert_encodable(FileRead.Handler.execute(%{"path" => path}, ctx()))
    end

    # A UTF-8 sequence cut in half by a byte-bounded read is the OTHER way
    # invalid bytes appear — malformed by us rather than by the file.
    test "a file ending in a bisected multi-byte codepoint stays encodable", %{dir: dir} do
      <<head::binary-size(2), _rest::binary>> = "🙈"
      path = write(dir, "cut.txt", "tail marker " <> head)

      assert_encodable(FileRead.Handler.execute(%{"path" => path}, ctx()))
      assert_encodable(FileRead.Handler.execute(%{"path" => path, "offset" => 1}, ctx()))
    end
  end

  # ── codebase_explore ────────────────────────────────────────────────────

  describe "codebase_explore over a tree containing non-UTF-8 files" do
    test "its summary is encodable", %{dir: dir} do
      latin1_source(dir)
      write(dir, "blob.bin", <<0, 1, 2, 0xDA, 0xFF, 0, 3>>)
      write(dir, "ok.ex", "defmodule Ok do\nend\n")

      assert_encodable(CodebaseExplore.execute(%{"path" => dir}))
    end
  end

  defp ctx, do: %OptimalSystemAgent.Tools.UseContext{}
end
