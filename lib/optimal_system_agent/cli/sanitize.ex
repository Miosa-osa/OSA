defmodule OptimalSystemAgent.CLI.Sanitize do
  @moduledoc """
  Character policy for text OSA prints to the operator's terminal.

  ## Why

  A terminal is an interpreter, and the text OSA prints is not all first-party.
  Model output is chosen by the model; tool output is whatever was on disk, on
  the network, or on a subprocess's stdout. Any of it can carry control
  sequences the terminal will *act on* rather than display:

    * `ESC ] 0 ; … BEL` rewrites the window title,
    * `ESC [ 2 J` and `ESC [ row ; col H` erase and reposition, which lets text
      already on screen be overdrawn — a consent prompt can be made to read
      differently from the action it is about to authorize,
    * `ESC [ ? 1049 h` swaps the alternate screen buffer,
    * `ESC ] 52 ; c ; <base64> BEL` **writes the operator's clipboard**, so
      their next paste is attacker-chosen,
    * `ESC [ c` and `ESC [ 6 n` are *queries*: the terminal replies by writing
      onto the application's **stdin**. That is injection into the next prompt —
      input the operator never typed.

  The Rust TUI has defended each of its display sites for some time
  (`priv/rust/tui/src/render/sanitize.rs`). This module is the Elixir
  counterpart, for the plain-CLI surfaces the TUI does not cover: headless
  `mix osa.run`, `cli/remote.ex`, and the CLI REPL.

  This is a *different* concern from `OptimalSystemAgent.Utils.WireEncoding`,
  which scrubs outbound provider messages for UTF-8 validity. ESC is perfectly
  valid UTF-8 and passes that scrub untouched.

  ## Policy

  Drop characters rather than parse sequences. Parsing invites disagreement with
  the terminal about where a sequence ends, and a sequence split across two
  streaming deltas would slip through a parser that only sees one chunk. Dropping
  is chunk-independent and idempotent: an `ESC` loses its meaning in whichever
  chunk carries it, and the remainder degrades to inert text (`]0;PWNED`), which
  is deliberate — the operator still sees that something was there.

  Nothing here strips OSA's *own* styling. Callers scrub untrusted text and then
  wrap it in their own colour codes, so the SGR that reaches the terminal is only
  ever OSA's.

  ## Tiers

    * `scrub_block/1` — keeps `\\n` and `\\t`; for multi-line bodies.
    * `scrub_line/1` — also drops newlines, so untrusted text cannot turn one
      display line into several and forge surrounding output.
  """

  # Zero-width, bidi-override and other invisible formatting codepoints. These
  # do not drive the terminal but they hide content from the reader (Trojan
  # Source), which matters most on the consent surfaces.
  @invisible [
    0x00AD,
    0x061C,
    0x180E,
    0x200B,
    0x200C,
    0x200D,
    0x200E,
    0x200F,
    0x202A,
    0x202B,
    0x202C,
    0x202D,
    0x202E,
    0x2060,
    0x2061,
    0x2062,
    0x2063,
    0x2064,
    0x2066,
    0x2067,
    0x2068,
    0x2069,
    0x206A,
    0x206B,
    0x206C,
    0x206D,
    0x206E,
    0x206F,
    0xFEFF,
    0xFFF9,
    0xFFFA,
    0xFFFB
  ]

  @doc """
  Scrub a multi-line body. Keeps `\\n` and `\\t`; drops every other control
  character, the C1 range, and invisible formatting codepoints.

  Non-binary input is returned unchanged so call sites can stay total.
  """
  @spec scrub_block(term()) :: term()
  def scrub_block(text) when is_binary(text), do: scrub(text, _keep_newlines = true)
  def scrub_block(other), do: other

  @doc """
  Scrub text that must stay on a single display line — status lines, tool
  argument hints, consent-box fields.

  Newlines and carriage returns are dropped rather than kept: `\\r` alone lets
  untrusted text overwrite a line already printed, and `\\n` lets one field forge
  the lines around it.
  """
  @spec scrub_line(term()) :: term()
  def scrub_line(text) when is_binary(text), do: scrub(text, _keep_newlines = false)
  def scrub_line(other), do: other

  defp scrub(text, keep_newlines) do
    text
    |> ensure_utf8()
    |> String.to_charlist()
    |> Enum.reduce([], fn cp, acc ->
      if keep?(cp, keep_newlines), do: [cp | acc], else: acc
    end)
    |> Enum.reverse()
    |> List.to_string()
  rescue
    # A renderer must never be the thing that crashes the session. Falling back
    # to a printable-ASCII filter still removes ESC.
    _ ->
      text
      |> :binary.bin_to_list()
      |> Enum.filter(&(&1 >= 0x20 and &1 < 0x7F))
      |> List.to_string()
  end

  defp keep?(?\n, keep_newlines), do: keep_newlines
  defp keep?(?\t, keep_newlines), do: keep_newlines
  defp keep?(cp, _) when cp < 0x20, do: false
  defp keep?(cp, _) when cp >= 0x7F and cp <= 0x9F, do: false
  defp keep?(cp, _) when cp in @invisible, do: false
  defp keep?(_cp, _), do: true

  # Invalid byte sequences would blow up `String.to_charlist/1`. Replace them
  # the same way `Utils.scrub_utf8/1` does rather than dropping the whole string.
  defp ensure_utf8(text) do
    if String.valid?(text), do: text, else: do_ensure_utf8(text, [])
  end

  defp do_ensure_utf8(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_ensure_utf8(<<cp::utf8, rest::binary>>, acc),
    do: do_ensure_utf8(rest, [<<cp::utf8>> | acc])

  defp do_ensure_utf8(<<_bad, rest::binary>>, acc),
    do: do_ensure_utf8(rest, ["�" | acc])
end
