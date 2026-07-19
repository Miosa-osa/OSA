defmodule OptimalSystemAgent.Shell.Pty.Keys do
  @moduledoc """
  Vim-style key-notation parser — converts strings like `"hello<CR>"`,
  `"<C-c>"`, `"<Esc>:wq<CR>"` into the raw terminal byte sequences a real
  program reads from its tty.

  Ported from grok's `ptyctl/src/keys.rs` (which leans on the `terminput`
  crate). This is a pragmatic, dependency-free reimplementation covering the
  notation an agent actually needs: literal text, control chords, the named
  special keys, and the arrow/function keys via their xterm escape sequences.

  ## Grammar

    * Literal characters pass through as their UTF-8 bytes.
    * `<...>` is a special token:
        * `<CR>` / `<Enter>` / `<Return>` → `\\r`
        * `<LF>`                          → `\\n`
        * `<Esc>` / `<Escape>`           → `\\e`
        * `<Tab>`  `<BS>` `<Space>` `<Del>` …
        * `<Up> <Down> <Left> <Right> <Home> <End> <PageUp> <PageDown>`
        * `<F1>`..`<F12>`
        * `<C-x>` control chord (any letter/char), `<M-x>`/`<A-x>` alt (ESC prefix)
        * `<lt>` `<gt>` `<bar>` `<bslash>` literal `< > | \\`
    * An unterminated `<` is treated as a literal `<`.

  Parsing never raises — an unknown `<...>` token is emitted verbatim (bytes of
  the raw token) so a typo degrades to visible text instead of crashing a send.
  """

  @doc """
  Parse `input` (vim notation) into raw terminal bytes.

  Always returns a binary; unknown tokens are passed through literally.
  """
  @spec parse(String.t()) :: binary()
  def parse(input) when is_binary(input) do
    input
    |> scan([])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  # ── Scanner ────────────────────────────────────────────────────────────

  defp scan("", acc), do: acc

  defp scan("<" <> rest, acc) do
    case String.split(rest, ">", parts: 2) do
      [token, tail] ->
        scan(tail, [encode_special(token) | acc])

      # No closing '>' — treat '<' as a literal character.
      [_only] ->
        scan(rest, ["<" | acc])
    end
  end

  defp scan(<<cp::utf8, rest::binary>>, acc) do
    scan(rest, [<<cp::utf8>> | acc])
  end

  # Defensive: any stray non-utf8 byte passes through untouched.
  defp scan(<<b, rest::binary>>, acc), do: scan(rest, [<<b>> | acc])

  # ── Special token encoding ─────────────────────────────────────────────

  defp encode_special(token) do
    lower = String.downcase(token)

    cond do
      # Control chord: <C-x>, <C-S-x>, etc. Modifiers stripped, ctrl folds the
      # final char into its C0 control byte (mask 0x1f), matching a real tty.
      match = Regex.run(~r/^(?:c-|ctrl-)(.+)$/, lower) ->
        [_, key] = match
        ctrl_byte(key)

      # Alt/Meta chord: ESC prefix then the (un-lowered) key bytes.
      match = Regex.run(~r/^(?:m-|a-|alt-|meta-)(.+)$/i, token) ->
        [_, key] = match
        <<0x1B>> <> parse(key)

      true ->
        named(lower) || literal_token(token)
    end
  end

  # A control chord: letter → Ctrl code (a→0x01 … z→0x1a), plus the handful of
  # named controls a tty produces (space→NUL, `[`→ESC, etc.).
  defp ctrl_byte(key) do
    case key do
      "space" -> <<0>>
      "@" -> <<0>>
      "[" -> <<0x1B>>
      "\\" -> <<0x1C>>
      "]" -> <<0x1D>>
      "^" -> <<0x1E>>
      "_" -> <<0x1F>>
      <<c>> when c in ?a..?z -> <<c - ?a + 1>>
      <<c>> when c in ?A..?Z -> <<c - ?A + 1>>
      # Fall back to masking the first byte (covers digits/symbols reasonably).
      <<c, _::binary>> -> <<Bitwise.band(c, 0x1F)>>
      _ -> <<>>
    end
  end

  defp named(lower) do
    case lower do
      k when k in ["cr", "enter", "return"] -> "\r"
      "lf" -> "\n"
      k when k in ["esc", "escape"] -> "\e"
      k when k in ["bs", "backspace"] -> <<0x7F>>
      "tab" -> "\t"
      k when k in ["space", "spc"] -> " "
      k when k in ["del", "delete"] -> "\e[3~"
      k when k in ["nul", "null"] -> <<0>>
      "up" -> "\e[A"
      "down" -> "\e[B"
      "right" -> "\e[C"
      "left" -> "\e[D"
      "home" -> "\e[H"
      "end" -> "\e[F"
      k when k in ["pageup", "pgup"] -> "\e[5~"
      k when k in ["pagedown", "pgdn"] -> "\e[6~"
      k when k in ["insert", "ins"] -> "\e[2~"
      "lt" -> "<"
      "gt" -> ">"
      "bar" -> "|"
      "bslash" -> "\\"
      "f1" -> "\eOP"
      "f2" -> "\eOQ"
      "f3" -> "\eOR"
      "f4" -> "\eOS"
      "f5" -> "\e[15~"
      "f6" -> "\e[17~"
      "f7" -> "\e[18~"
      "f8" -> "\e[19~"
      "f9" -> "\e[20~"
      "f10" -> "\e[21~"
      "f11" -> "\e[23~"
      "f12" -> "\e[24~"
      _ -> nil
    end
  end

  # Unknown token — emit it verbatim (with the angle brackets) so a typo is
  # visible rather than silently dropped.
  defp literal_token(token), do: "<" <> token <> ">"
end
