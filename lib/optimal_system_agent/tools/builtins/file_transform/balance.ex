defmodule OptimalSystemAgent.Tools.Builtins.FileTransform.Balance do
  @moduledoc """
  Delimiter balance that knows what a string literal and a comment are.

  ## Why this is not `:binary.matches/2`

  `assert_balanced` began as a character count: occurrences of `open` minus
  occurrences of `close`. That is what codex's twelve paren probes did on a
  Scheme file, and on a Scheme file it is right, because Scheme has no `)` in a
  comment often enough to matter.

  On anything else it is wrong in both directions, and both were measured on
  this tree:

      int main() { return 0; } // trailing brace in a comment: }
      #=> balance: -1 — 1 extra } with no matching {. Nothing was written.

  That file is valid C. The counter refused it, and because `assert_balanced`
  aborts the whole transform, a correct edit in the same operation list was
  discarded on the strength of a brace inside a comment. The opposite direction
  is quieter and worse: a genuinely broken file whose damage happens to be
  cancelled out by a delimiter inside a string reports `balance: 0`, and the
  model builds three more edits on top of a file it has been told is fine.

  So the scan skips what a compiler would skip. It is still not a parser — it
  makes no claim about grammar, only about delimiters — but it no longer counts
  characters that are not delimiters.

  ## What it knows

  A *syntax family* is inferred from the file extension. Each family says what
  starts a comment and what starts a string:

    * `:c` — `//`, `/* */`, `"…"`, `'…'`, backslash escapes.
      C, C++, Go, Java, Kotlin, C#, Swift, Scala, PHP, JS/TS.
    * `:rust` — as `:c`, but `'` starts nothing, because it is a lifetime.
    * `:python` — `#`, `"…"`, `'…'`, and both triple-quoted forms.
    * `:hash` — `#`, `"…"`, `'…'`. Shell, Ruby, Perl, YAML, TOML, R.
    * `:elixir` — `#`, `"…"`, `'…'`, `\"\"\"` heredocs, `?c` char literals.
    * `:lisp` — `;`, `"…"`. Scheme, Common Lisp, Clojure, Elisp, Racket.
    * `:json` — `"…"` only; JSON has no comments.

  An extension with no family — and a call with no path at all — falls back to
  the original character count and **says so in its result**, because a check
  that silently means something weaker than the caller thinks is the failure
  this module exists to remove.

  ## What it deliberately does not know

  Rust raw strings (`r#"…"#`), Rust char literals, Python raw strings ending in a backslash, and
  Elixir sigils are not modelled. Each of them can still mis-scan. They are rare
  next to the two cases above, and the honest statement of the guarantee is:
  *this is a delimiter scan that ignores ordinary strings and comments*, not a
  lexer for any particular language.
  """

  @c_family ~w(.c .h .cc .cpp .cxx .hpp .hh .js .mjs .cjs .jsx .ts .tsx .go
               .java .kt .kts .cs .swift .scala .php .m .mm .dart .groovy .proto)

  # Rust is `:c` minus single-quoted strings. `'a` in `fn f<'a>(x: &'a str)` is a
  # lifetime, not the start of a literal, and treating it as one swallows the
  # rest of the signature — lifetimes are far commoner in Rust than the `'('`
  # char literal that this gives up.
  @rust_family ~w(.rs)

  @hash_family ~w(.sh .bash .zsh .rb .pl .pm .yaml .yml .toml .r .tf .mk)

  @lisp_family ~w(.scm .ss .lisp .lsp .el .clj .cljs .cljc .rkt)

  @families Map.new(
              Enum.map(@c_family, &{&1, :c}) ++
                Enum.map(@hash_family, &{&1, :hash}) ++
                Enum.map(@rust_family, &{&1, :rust}) ++
                Enum.map(@lisp_family, &{&1, :lisp}) ++
                [
                  {".py", :python},
                  {".pyi", :python},
                  {".ex", :elixir},
                  {".exs", :elixir},
                  {".heex", :elixir},
                  {".json", :json}
                ]
            )

  @doc """
  Syntax family for a path, or `nil` when the extension is unknown or no path
  was supplied.
  """
  @spec family(String.t() | nil) :: atom() | nil
  def family(nil), do: nil

  def family(path) when is_binary(path) do
    Map.get(@families, path |> Path.extname() |> String.downcase())
  end

  def family(_), do: nil

  @doc """
  Check that `open`/`close` are balanced in `content`.

  Returns `{:ok, report}` or `{:error, report}`. Both are single lines and
  neither carries any of the file — that is the whole point of the operation.

  `family` may be `nil`, in which case this degrades to the raw character count
  and the report names the degradation.
  """
  @spec check(String.t(), String.t(), String.t(), atom() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def check(content, open, close, family)

  # Same character for open and close (`"` against `"`, say) has no stack
  # semantics — there is no way to tell an opener from a closer — so parity is
  # the only meaningful question and the raw count is the right answer.
  def check(content, same, same, _family),
    do: raw(content, same, same, "open and close are the same character")

  def check(content, open, close, nil),
    do: raw(content, open, close, "strings and comments NOT excluded — unknown file type")

  def check(content, open, close, family) do
    case scan(content, open, close, family) do
      {:ok, []} ->
        {:ok, "balance: 0 (#{open}#{close} balanced, ignoring strings and comments)"}

      {:ok, [line | _] = stack} ->
        n = length(stack)

        {:error,
         "balance: #{n} — #{n} unclosed #{open} (missing #{n} #{close}), " <>
           "the first still open from line #{line}. Nothing was written."}

      {:unmatched_close, line} ->
        {:error,
         "balance: -1 — an extra #{close} with no matching #{open}, at line #{line}. " <>
           "Nothing was written."}
    end
  end

  # ── the fallback: what this operation used to always do ───────────────

  defp raw(content, open, close, why) do
    balance = length(:binary.matches(content, open)) - length(:binary.matches(content, close))

    if balance == 0 do
      {:ok, "balance: 0 (#{open}#{close} balanced; #{why})"}
    else
      {:error,
       "balance: #{balance} — #{hint(balance, open, close)}; #{why}. Nothing was written."}
    end
  end

  defp hint(balance, open, close) when balance > 0,
    do: "#{balance} unclosed #{open} (missing #{balance} #{close})"

  defp hint(balance, open, close),
    do: "#{abs(balance)} extra #{close} with no matching #{open}"

  # ── the scan ──────────────────────────────────────────────────────────
  #
  # One pass over the binary. `stack` holds the line number of every currently
  # open delimiter, most recent first, so an unclosed opener can be reported at
  # the line it was opened on rather than as a bare count.

  defp scan(content, open, close, family) do
    walk(content, :code, 1, [], %{open: open, close: close, family: family})
  end

  defp walk(<<>>, _state, _line, stack, _cfg), do: {:ok, stack}

  # Newlines advance the line counter and end a line comment, in every state
  # except a block comment or a heredoc/triple-quoted string.
  defp walk(<<"\n", rest::binary>>, :line_comment, line, stack, cfg),
    do: walk(rest, :code, line + 1, stack, cfg)

  defp walk(<<"\n", rest::binary>>, state, line, stack, cfg),
    do: walk(rest, state, line + 1, stack, cfg)

  # ── inside a line comment: nothing counts ─────────────────────────────
  defp walk(<<_::binary-size(1), rest::binary>>, :line_comment, line, stack, cfg),
    do: walk(rest, :line_comment, line, stack, cfg)

  # ── inside a block comment: only its terminator counts ────────────────
  defp walk(<<"*/", rest::binary>>, :block_comment, line, stack, cfg),
    do: walk(rest, :code, line, stack, cfg)

  defp walk(<<_::binary-size(1), rest::binary>>, :block_comment, line, stack, cfg),
    do: walk(rest, :block_comment, line, stack, cfg)

  # ── inside a string: escapes, then the terminator ─────────────────────
  defp walk(<<"\\", _skipped::binary-size(1), rest::binary>>, {:string, _} = s, line, stack, cfg),
    do: walk(rest, s, line, stack, cfg)

  defp walk(<<"\\", _skipped::binary-size(1), rest::binary>>, {:triple, _} = s, line, stack, cfg),
    do: walk(rest, s, line, stack, cfg)

  defp walk(content, {:triple, q}, line, stack, cfg) do
    case content do
      <<^q::binary-size(3), rest::binary>> -> walk(rest, :code, line, stack, cfg)
      <<_::binary-size(1), rest::binary>> -> walk(rest, {:triple, q}, line, stack, cfg)
    end
  end

  defp walk(content, {:string, q}, line, stack, cfg) do
    case content do
      <<^q::binary-size(1), rest::binary>> -> walk(rest, :code, line, stack, cfg)
      <<_::binary-size(1), rest::binary>> -> walk(rest, {:string, q}, line, stack, cfg)
    end
  end

  # ── in code ───────────────────────────────────────────────────────────
  defp walk(content, :code, line, stack, cfg) do
    cond do
      comment_start = comment_start(content, cfg.family) ->
        {kind, len} = comment_start
        <<_::binary-size(len), rest::binary>> = content
        walk(rest, kind, line, stack, cfg)

      triple = triple_start(content, cfg.family) ->
        <<_::binary-size(3), rest::binary>> = content
        walk(rest, {:triple, triple}, line, stack, cfg)

      # `?)` in Elixir is the character literal for `)`, not a delimiter.
      cfg.family == :elixir and match?(<<"?", _::binary-size(1), _::binary>>, content) ->
        <<_::binary-size(2), rest::binary>> = content
        walk(rest, :code, line, stack, cfg)

      q = string_start(content, cfg.family) ->
        <<_::binary-size(1), rest::binary>> = content
        walk(rest, {:string, q}, line, stack, cfg)

      true ->
        delimiter(content, line, stack, cfg)
    end
  end

  defp delimiter(content, line, stack, cfg) do
    open = cfg.open
    close = cfg.close

    case content do
      <<^open::binary-size(1), rest::binary>> ->
        walk(rest, :code, line, [line | stack], cfg)

      <<^close::binary-size(1), rest::binary>> ->
        case stack do
          [_ | tail] -> walk(rest, :code, line, tail, cfg)
          [] -> {:unmatched_close, line}
        end

      <<_::binary-size(1), rest::binary>> ->
        walk(rest, :code, line, stack, cfg)
    end
  end

  # ── family rules ──────────────────────────────────────────────────────

  defp comment_start(<<"//", _::binary>>, f) when f in [:c, :rust], do: {:line_comment, 2}
  defp comment_start(<<"/*", _::binary>>, f) when f in [:c, :rust], do: {:block_comment, 2}

  defp comment_start(<<"#", _::binary>>, f) when f in [:python, :hash, :elixir],
    do: {:line_comment, 1}

  defp comment_start(<<";", _::binary>>, :lisp), do: {:line_comment, 1}
  defp comment_start(_, _), do: nil

  defp triple_start(<<"\"\"\"", _::binary>>, f) when f in [:python, :elixir], do: "\"\"\""
  defp triple_start(<<"'''", _::binary>>, :python), do: "'''"
  defp triple_start(_, _), do: nil

  defp string_start(<<"\"", _::binary>>, _family), do: "\""
  defp string_start(<<"'", _::binary>>, f) when f in [:c, :python, :hash, :elixir], do: "'"
  defp string_start(_, _), do: nil
end
