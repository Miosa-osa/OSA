defmodule OptimalSystemAgent.Agent.Safety.CommandVariants do
  @moduledoc """
  NORMALIZATION for the safety matchers: turn ONE raw command string into the
  SET of strings that describe what the kernel will actually run.

  ## Why this exists

  Every pattern-based safety check in OSA used to read the *raw, pre-shell*
  command string, while the shell strips quoting and unwraps interpreters before
  `rm` (or `mkfs`, or `dd`) ever sees its arguments. That mismatch made the
  "non-bypassable" circuit-breaker trivially bypassable:

      rm -rf /          → blocked
      rm -rf "/"        → PASSED   (a quote is not a word boundary)
      rm -rf '/'        → PASSED
      "rm" -rf /        → PASSED
      rm -rf \\/         → PASSED
      bash -c "rm -rf /" → PASSED  (opaque payload; head is `bash`, not `rm`)

  All six execute identically. Hardening the regexes cannot win this race —
  there are unbounded encodings of the same command. So instead of teaching each
  matcher about quoting, we normalize the INPUT and run the existing predicates
  over every variant. A match on ANY variant is a match.

  ## The variant set

  For a command `c`, `variants/1` returns (deduplicated, raw first):

    1. `c` itself — nothing is ever weakened; the old behaviour is a subset.
    2. `normalize(c)` — shell-unquoted: matched `'…'` / `"…"` pairs removed and
       backslash escapes resolved, token by token.
    3. the payloads of any *wrapper*, extracted recursively:
         * interpreter `-c` / `-e`: `bash -c …`, `sh -lc …`, `zsh -c …`,
           `python3 -c …`, `perl -e …`, `node -e …`, `ruby -e …`
         * `find … -exec CMD … ;`, `xargs [flags] CMD …`
         * transparent prefixes: `env`, `sudo`, `doas`, `nohup`, `timeout`,
           `command`, `exec`, `setsid`, `nice`, `ionice`, `stdbuf`, `time`
    4. steps 2–3 applied again to each new variant, to a bounded depth, so
       `bash -c "sudo rm -rf '/'"` reduces all the way down to `rm -rf /`.

  Quoting is handled by REUSING `ShellExecute.Parser.tokenize/1` — the same
  quote/escape/substitution-aware tokenizer the permission layer already uses. A
  second, independently-written tokenizer that disagreed with the first would
  simply be a new hole.

  The module is pure: no I/O, no state, no config. Growth is bounded by
  `@max_depth`, `@max_variants` and `@max_length` so a hostile input cannot turn
  the safety gate into a fork bomb of its own.
  """

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Parser

  # Recursion bound for wrapper unwrapping (`bash -c "sudo bash -c …"`).
  @max_depth 5
  # Hard cap on the size of the returned set.
  @max_variants 64
  # Beyond this size we do not attempt to derive variants — a megabyte-long
  # heredoc must not make the permission gate expensive. The raw string is still
  # checked, so this can only ever be as weak as the pre-existing behaviour.
  @max_length 20_000

  # Shells: their `-c` argument is a shell command.
  @shell_interpreters ~w(sh bash zsh dash ksh fish ash busybox)

  # Other interpreters: their `-c` / `-e` argument is source that very commonly
  # embeds a shell command (`python -c 'os.system("rm -rf /")'`).
  @code_interpreters ~w(python python2 python3 perl ruby node nodejs deno php)

  # Prefixes that run their remaining arguments as a command, unchanged.
  @transparent ~w(env sudo doas nohup timeout command exec setsid nice ionice stdbuf time)

  # Flags of a transparent prefix that consume the NEXT token as their operand,
  # so it is not mistaken for the wrapped command's head.
  @flags_with_operand %{
    "sudo" => ~w(-u -g -p -C -D -R --user --group --prompt --chdir),
    "doas" => ~w(-u -C),
    "env" => ~w(-u -C --unset --chdir),
    "timeout" => ~w(-k -s --kill-after --signal),
    "nice" => ~w(-n --adjustment),
    "ionice" => ~w(-n -c -p),
    "stdbuf" => ~w(-i -o -e)
  }

  @doc """
  The set of command strings equivalent to `command` after shell processing.

  The raw input is always the first element. Returns `[]` for non-binaries.

  Over `@max_length` the input is not returned raw — see `oversize_variants/1`
  for why that would be a bypass, and `fully_analyzed?/1` for how a caller
  learns the analysis was partial.
  """
  @spec variants(term()) :: [String.t()]
  def variants(command) when is_binary(command) do
    if byte_size(command) > @max_length do
      oversize_variants(command)
    else
      expand([command], 1, MapSet.new([command]), [command])
    end
  end

  def variants(_), do: []

  @doc """
  True when `variants/1` was able to derive the COMPLETE equivalent set for
  `command` — i.e. the command fits the size bound and the variant set was not
  truncated by `@max_variants`.

  A size bound on a safety analysis must fail CLOSED. `false` here does not
  mean "dangerous"; it means "not proven safe", and a caller that would
  otherwise auto-approve must ask instead. `variants/1` used to hand back the
  raw, still-quoted string for anything over 20 KB, so padding `rm -rf "/"`
  with 20 KB of comment walked straight through the hard-deny tier.
  """
  @spec fully_analyzed?(term()) :: boolean()
  def fully_analyzed?(command) when is_binary(command) do
    byte_size(command) <= @max_length and
      elem(expand([command], 1, MapSet.new([command]), [command], true), 1)
  end

  def fully_analyzed?(_), do: false

  # An over-length command still gets analysed — just not exhaustively.
  #
  # The realistic attack is padding: the dangerous command is short and sits
  # next to a wall of filler that exists only to trip the size bound. So we
  # classify BEFORE bounding, over inputs that are each individually within
  # budget:
  #
  #   * every shell statement (split on `;`, `&&`, `||`, `|`, newline) that is
  #     itself short enough — catches `rm -rf "/" ; echo <20KB>`;
  #   * the first `@max_length` bytes of the whole command — catches padding
  #     that is a trailing comment or heredoc rather than a separate statement,
  #     e.g. `bash -c "rm -rf '/'" # <20KB>`.
  #
  # The raw command is retained as well, so this is strictly stronger than the
  # old behaviour, never weaker. Growth stays bounded: the head is capped at
  # `@max_length` and the statement list at `@max_variants`.
  defp oversize_variants(command) do
    head = binary_part(command, 0, @max_length)

    statements =
      command
      |> String.split(~r/;|&&|\|\||\||\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or byte_size(&1) > @max_length))
      |> Enum.take(@max_variants)

    seeds = Enum.uniq([head | statements])

    derived =
      Enum.flat_map(seeds, fn seed ->
        expand([seed], 1, MapSet.new([seed]), [seed])
      end)

    [command | derived]
    |> Enum.uniq()
    |> Enum.take(@max_variants * 2)
  end

  @doc """
  True when `fun` returns a truthy value for ANY variant of `command`.

  This is the shape every safety predicate should use: `any?(cmd, &match?/1)`
  rather than `match?(cmd)`.
  """
  @spec any?(term(), (String.t() -> as_boolean(term()))) :: boolean()
  def any?(command, fun) when is_function(fun, 1) do
    command |> variants() |> Enum.any?(fun)
  end

  @doc """
  `command` with every token shell-unquoted: matched quote pairs removed and
  backslash escapes resolved. Operators and redirections are preserved in order.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(command) when is_binary(command) do
    command
    |> safe_tokenize()
    |> Enum.map(fn
      {:word, w} -> shell_unquote(w)
      {:op, o} -> o
      {:redir, r} -> r
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  @doc """
  Strip shell quoting from a single raw token: `"/"` → `/`, `'~'` → `~`,
  `\\/` → `/`, `a"b"c` → `abc`.

  Unlike `Parser.unquote_token/1` (which removes at most ONE matched outer pair)
  this resolves quoting wherever it appears inside the token, which is exactly
  what the shell does before the command is executed.
  """
  @spec shell_unquote(String.t()) :: String.t()
  def shell_unquote(raw) when is_binary(raw), do: unq(raw, [])
  def shell_unquote(other), do: other

  # ── expansion ─────────────────────────────────────────────────────────

  # `expand/4` keeps the historic "just give me the list" shape; `expand/5`
  # additionally reports whether the search RAN OUT of budget with work still
  # pending. That distinction is the whole point: a frontier abandoned at the
  # depth or variant bound means unexamined encodings still exist, so "nothing
  # dangerous matched" is not a safety result.
  defp expand(frontier, depth, seen, acc) do
    {list, _complete?} = expand(frontier, depth, seen, acc, true)
    list
  end

  defp expand(frontier, depth, _seen, acc, complete?) when depth > @max_depth,
    do: {Enum.reverse(acc), complete? and frontier == []}

  defp expand([], _depth, _seen, acc, complete?), do: {Enum.reverse(acc), complete?}

  defp expand(frontier, depth, seen, acc, complete?) do
    if length(acc) >= @max_variants do
      {Enum.reverse(acc), false}
    else
      {next, seen, acc, complete?} =
        Enum.reduce(frontier, {[], seen, acc, complete?}, fn cmd, {next, seen, acc, complete?} ->
          cmd
          |> derive()
          |> Enum.reduce({next, seen, acc, complete?}, fn v, {next, seen, acc, complete?} ->
            cond do
              v == "" or MapSet.member?(seen, v) ->
                {next, seen, acc, complete?}

              length(acc) >= @max_variants ->
                # Dropped for budget, not because it was uninteresting.
                {next, seen, acc, false}

              true ->
                {[v | next], MapSet.put(seen, v), [v | acc], complete?}
            end
          end)
        end)

      expand(Enum.reverse(next), depth + 1, seen, acc, complete?)
    end
  end

  # One expansion step for a single command: its unquoted form plus every
  # wrapper payload it carries.
  defp derive(command) do
    normalized = normalize(command)
    [normalized | payloads(command) ++ payloads(normalized)] |> Enum.uniq()
  end

  # ── wrapper payload extraction ────────────────────────────────────────

  defp payloads(command) do
    command
    |> safe_segments()
    |> Enum.flat_map(&segment_payloads/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp segment_payloads(tokens) do
    words = for {:word, w} <- tokens, do: shell_unquote(w)

    case words do
      [] ->
        []

      [head_raw | args] ->
        head = head_basename(head_raw)

        cond do
          head in @shell_interpreters -> dash_flag_payload(args, ~r/^--?[a-zA-Z]*c$/)
          head in @code_interpreters -> dash_flag_payload(args, ~r/^--?[a-zA-Z]*[ce]$/)
          head == "find" -> find_exec_payload(args)
          head == "xargs" -> [join(strip_leading_opts(args, "xargs"))]
          head in @transparent -> [join(strip_leading_opts(args, head))]
          true -> []
        end
    end
  end

  # `bash -c <payload> [extra…]` — the payload argument itself, and (for the
  # `sh -c 'cmd' -- args` shape and for already-normalized input where the
  # payload was flattened into several tokens) the whole remainder.
  defp dash_flag_payload(args, flag_re) do
    case Enum.find_index(args, &Regex.match?(flag_re, &1)) do
      nil ->
        []

      idx ->
        rest = Enum.drop(args, idx + 1)

        case rest do
          [] -> []
          [payload | _] -> Enum.uniq([payload, join(rest)])
        end
    end
  end

  # `find … -exec CMD … \;` / `-execdir CMD … +`
  defp find_exec_payload(args) do
    case Enum.find_index(args, &(&1 in ["-exec", "-execdir", "-ok", "-okdir"])) do
      nil ->
        []

      idx ->
        args
        |> Enum.drop(idx + 1)
        |> Enum.take_while(&(&1 not in [";", "+"]))
        |> join()
        |> List.wrap()
    end
  end

  # Drop a transparent prefix's own options (and `VAR=value` assignments, and a
  # bare `timeout` duration) so what remains starts at the wrapped command.
  defp strip_leading_opts([], _head), do: []

  defp strip_leading_opts([tok | rest] = all, head) do
    cond do
      operand_flag?(head, tok) -> strip_leading_opts(drop_operand(rest), head)
      String.starts_with?(tok, "-") -> strip_leading_opts(rest, head)
      assignment?(tok) -> strip_leading_opts(rest, head)
      head == "timeout" and duration?(tok) -> strip_leading_opts(rest, head)
      true -> all
    end
  end

  defp operand_flag?(head, tok), do: tok in Map.get(@flags_with_operand, head, [])

  defp drop_operand([next | rest]) do
    if String.starts_with?(next, "-"), do: [next | rest], else: rest
  end

  defp drop_operand([]), do: []

  defp assignment?(tok), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, tok)
  defp duration?(tok), do: Regex.match?(~r/^\d+(?:\.\d+)?[smhd]?$/, tok)

  defp join(words), do: words |> Enum.join(" ") |> String.trim()

  defp head_basename(word) do
    word
    |> String.replace(~r/^\\+/, "")
    |> Path.basename()
  end

  # ── defensive wrappers around the shared tokenizer ────────────────────

  defp safe_tokenize(command) do
    Parser.tokenize(command)
  rescue
    _ -> [{:word, command}]
  catch
    _, _ -> [{:word, command}]
  end

  defp safe_segments(command) do
    Parser.segments(command)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # ── shell unquoting ───────────────────────────────────────────────────

  defp unq(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp unq(<<?', rest::binary>>, acc) do
    {seg, rest2} = read_single(rest, [])
    unq(rest2, [seg | acc])
  end

  defp unq(<<?", rest::binary>>, acc) do
    {seg, rest2} = read_double(rest, [])
    unq(rest2, [seg | acc])
  end

  defp unq(<<?\\, c, rest::binary>>, acc), do: unq(rest, [<<c>> | acc])
  defp unq(<<?\\>>, acc), do: unq(<<>>, acc)
  defp unq(<<c, rest::binary>>, acc), do: unq(rest, [<<c>> | acc])

  # Single quotes: everything is literal until the closing quote.
  defp read_single(<<?', rest::binary>>, acc), do: {IO.iodata_to_binary(acc), rest}
  defp read_single(<<c, rest::binary>>, acc), do: read_single(rest, [acc, c])
  defp read_single(<<>>, acc), do: {IO.iodata_to_binary(acc), ""}

  # Double quotes: backslash escapes the next character; otherwise literal.
  defp read_double(<<?\\, c, rest::binary>>, acc), do: read_double(rest, [acc, c])
  defp read_double(<<?", rest::binary>>, acc), do: {IO.iodata_to_binary(acc), rest}
  defp read_double(<<c, rest::binary>>, acc), do: read_double(rest, [acc, c])
  defp read_double(<<>>, acc), do: {IO.iodata_to_binary(acc), ""}
end
