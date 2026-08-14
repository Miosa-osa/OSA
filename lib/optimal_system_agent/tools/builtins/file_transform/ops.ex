defmodule OptimalSystemAgent.Tools.Builtins.FileTransform.Ops do
  @moduledoc """
  The transform vocabulary: a pure `content -> content` interpreter.

  ## Why this is data and not a script

  The whole point of `file_transform` is that the model can mutate a file it is
  not holding in context. The obvious way to do that is codex's way — hand a
  `python3 - <<PY` heredoc to the shell and let the script open the file itself.
  That gives up the property this codebase is built on: the *file* is the unit
  of authorisation. A script that opens its own files declares nothing, so
  `PathPolicy.check_write/2` has nothing to check.

  So this module executes **no model-supplied code**. Every operation below is a
  fixed Elixir function selected by an atom; the model supplies only strings.
  There is no operation that takes a path, opens a file, spawns a process, or
  evaluates anything. The single file the tool touches is the one named in the
  tool call, and the handler is what touches it. That is a structural property,
  not a check that can be bypassed — see `docs/design/context-free-edits.md` §2.

  ## The expectation gate

  Every mutating operation is *anchored*: it names what it expects to find, and
  states how many times. If the count does not match, the whole transform aborts
  and nothing is written. This is codex's `assert old in src` promoted to a
  first-class part of the interface, and it does two jobs:

    * it is the correctness gate — a pattern that silently matched zero times is
      the exact failure mode that turns a "successful" edit into a corrupted
      file, and
    * it is the **staleness guard**. `file_edit` needs read-before-edit because
      an unanchored replacement of bytes the model believes are present can
      clobber a file that changed underneath it. An anchored operation with an
      exact expected count cannot: if the file changed in a way that matters to
      this edit, the count moves and the transform refuses.

  `append` and `prepend` are the two unanchored operations and they are
  deliberately additive — neither can destroy an existing byte. There is no
  line-number-addressed operation, because addressing a line by number in a file
  you have not read is precisely the blind clobber the anchoring is there to
  prevent.

  ## Vocabulary

      %{"op" => "replace",              "find" => lit, "to" => str, "expect" => n?}
      %{"op" => "replace_regex",        "pattern" => re, "to" => str, "expect" => n?}
      %{"op" => "delete_matching_lines","pattern" => re, "expect" => n?}
      %{"op" => "insert_after",         "pattern" => re, "text" => str, "expect" => n?}
      %{"op" => "insert_before",        "pattern" => re, "text" => str, "expect" => n?}
      %{"op" => "append",               "text" => str}
      %{"op" => "prepend",              "text" => str}
      %{"op" => "count",                "pattern" => re}
      %{"op" => "assert_balanced",      "open" => "(", "close" => ")"}

  `expect` is optional. Omitted, it means "at least one" — a zero-match
  mutation is always an error. Given as an integer, the match count must equal
  it exactly.

  `count` and `assert_balanced` mutate nothing. They exist so that the question
  *"is this file well-formed / how many X does it contain"* can be answered for
  the price of its answer rather than the price of the file, which is the
  measured difference between codex's 94k peak context and OSA's 201k.

  `assert_balanced` delegates to `FileTransform.Balance`, which skips string
  literals and comments when the file extension identifies a syntax family, and
  degrades to a bare character count — saying so in its report — when it does
  not. See that module for why the bare count was wrong in both directions.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileTransform.Balance

  @type op :: map()
  @type report :: String.t()

  @doc """
  Apply `ops` to `content` in order.

  Returns `{:ok, new_content, reports}` when every operation met its
  expectation, or `{:error, reason}` — in which case the caller must write
  nothing at all.
  """
  @spec apply_all(String.t(), [op()]) :: {:ok, String.t(), [report()]} | {:error, String.t()}
  def apply_all(content, ops), do: apply_all(content, ops, [])

  @doc """
  As `apply_all/2`, with `opts`.

  The only option is `:path` — the declared path, used *solely* to infer a
  syntax family for `assert_balanced` (see `FileTransform.Balance`). Nothing in
  this module opens it, and no operation can see it.
  """
  @spec apply_all(String.t(), [op()], keyword()) ::
          {:ok, String.t(), [report()]} | {:error, String.t()}
  def apply_all(content, ops, opts) when is_binary(content) and is_list(ops) do
    ops
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, content, []}, fn {op, idx}, {:ok, acc, reports} ->
      case apply_one(acc, op, opts) do
        {:ok, next, report} ->
          {:cont, {:ok, next, [numbered(idx, op, report) | reports]}}

        {:error, reason} ->
          {:halt, {:error, "operation #{idx} (#{op_name(op)}) failed: #{reason}"}}
      end
    end)
    |> case do
      {:ok, out, reports} -> {:ok, out, Enum.reverse(reports)}
      {:error, _} = err -> err
    end
  end

  defp numbered(idx, op, report), do: "  #{idx}. #{op_name(op)} — #{report}"

  defp op_name(%{"op" => name}) when is_binary(name), do: name
  defp op_name(_), do: "unknown"

  # ── Static validation (no file needed) ────────────────────────────────

  @doc """
  Type-check the operation list without touching the filesystem.

  Returns `:ok` or `{:error, message}`. Every message names the operation index
  and what specifically is wrong, because a schema rejection the model cannot
  act on costs a whole turn.
  """
  @spec validate([term()]) :: :ok | {:error, String.t()}
  def validate(ops) when is_list(ops) and ops != [] do
    ops
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {op, idx}, :ok ->
      case validate_one(op) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "operation #{idx}: #{msg}"}}
      end
    end)
  end

  def validate([]), do: {:error, "operations list is empty — nothing to do"}
  def validate(_), do: {:error, "operations must be a list of operation objects"}

  @known_ops ~w(replace replace_regex delete_matching_lines insert_after insert_before
                append prepend count assert_balanced)

  defp validate_one(%{"op" => name} = op) when is_binary(name) do
    cond do
      name not in @known_ops ->
        {:error, "unknown op #{inspect(name)}. Known ops: #{Enum.join(@known_ops, ", ")}"}

      true ->
        with :ok <- require_fields(op, name),
             :ok <- validate_expect(op) do
          validate_regex(op, name)
        end
    end
  end

  defp validate_one(%{}), do: {:error, "missing required key \"op\""}
  defp validate_one(_), do: {:error, "each operation must be an object"}

  @required %{
    "replace" => ["find", "to"],
    "replace_regex" => ["pattern", "to"],
    "delete_matching_lines" => ["pattern"],
    "insert_after" => ["pattern", "text"],
    "insert_before" => ["pattern", "text"],
    "append" => ["text"],
    "prepend" => ["text"],
    "count" => ["pattern"],
    "assert_balanced" => []
  }

  defp require_fields(op, name) do
    missing =
      @required
      |> Map.fetch!(name)
      |> Enum.reject(fn key -> is_binary(Map.get(op, key)) end)

    case missing do
      [] -> :ok
      keys -> {:error, "#{name} requires string #{Enum.map_join(keys, ", ", &inspect/1)}"}
    end
  end

  defp validate_expect(%{"expect" => n}) when is_integer(n) and n >= 0, do: :ok
  defp validate_expect(%{"expect" => nil}), do: :ok

  defp validate_expect(%{"expect" => other}),
    do: {:error, "expect must be a non-negative integer, got #{inspect(other)}"}

  defp validate_expect(_), do: :ok

  @regex_ops ~w(replace_regex delete_matching_lines insert_after insert_before count)

  defp validate_regex(%{"pattern" => pattern}, name) when name in @regex_ops do
    case Regex.compile(pattern) do
      {:ok, _} -> :ok
      {:error, {reason, at}} -> {:error, "invalid regex: #{reason} at offset #{at}"}
      {:error, reason} -> {:error, "invalid regex: #{inspect(reason)}"}
    end
  end

  defp validate_regex(_, _), do: :ok

  # ── Operations ────────────────────────────────────────────────────────

  defp apply_one(content, %{"op" => "replace", "find" => find, "to" => to} = op, _opts) do
    count = length(:binary.matches(content, find))

    with :ok <- check_count(op, count, "occurrences of the literal") do
      {:ok, String.replace(content, find, to), "#{count} replaced"}
    end
  end

  defp apply_one(
         content,
         %{"op" => "replace_regex", "pattern" => pattern, "to" => to} = op,
         _opts
       ) do
    with {:ok, re} <- compile(pattern) do
      count = length(Regex.scan(re, content))

      with :ok <- check_count(op, count, "regex matches") do
        {:ok, Regex.replace(re, content, to), "#{count} replaced"}
      end
    end
  end

  defp apply_one(content, %{"op" => "delete_matching_lines", "pattern" => pattern} = op, _opts) do
    with {:ok, re} <- compile(pattern) do
      {lines, eol} = split_lines(content)
      {kept, removed} = Enum.split_with(lines, &(not Regex.match?(re, &1)))

      with :ok <- check_count(op, length(removed), "matching lines") do
        {:ok, join_lines(kept, eol), "#{length(removed)} lines deleted"}
      end
    end
  end

  defp apply_one(
         content,
         %{"op" => "insert_after", "pattern" => pattern, "text" => text} = op,
         _opts
       ) do
    insert(content, op, pattern, text, :after)
  end

  defp apply_one(
         content,
         %{"op" => "insert_before", "pattern" => pattern, "text" => text} = op,
         _opts
       ) do
    insert(content, op, pattern, text, :before)
  end

  defp apply_one(content, %{"op" => "append", "text" => text}, _opts) do
    joined =
      if content == "" or String.ends_with?(content, "\n"), do: content, else: content <> "\n"

    {:ok, joined <> text, "#{byte_size(text)} bytes appended"}
  end

  defp apply_one(content, %{"op" => "prepend", "text" => text}, _opts) do
    sep = if text == "" or String.ends_with?(text, "\n"), do: "", else: "\n"
    {:ok, text <> sep <> content, "#{byte_size(text)} bytes prepended"}
  end

  defp apply_one(content, %{"op" => "count", "pattern" => pattern} = op, _opts) do
    with {:ok, re} <- compile(pattern) do
      count = length(Regex.scan(re, content))

      # `count` is a probe: it reports, and only fails when the caller stated an
      # expectation and it was not met. Without `expect` it never fails, so a
      # probe cannot abort a transform by accident.
      case Map.get(op, "expect") do
        nil -> {:ok, content, "#{count} matches (no change)"}
        n when n == count -> {:ok, content, "#{count} matches, as expected (no change)"}
        n -> {:error, "expected #{n} matches, found #{count}"}
      end
    end
  end

  defp apply_one(content, %{"op" => "assert_balanced"} = op, opts) do
    open = Map.get(op, "open", "(")
    close = Map.get(op, "close", ")")

    cond do
      not (is_binary(open) and byte_size(open) == 1) ->
        {:error, "open must be a single character"}

      not (is_binary(close) and byte_size(close) == 1) ->
        {:error, "close must be a single character"}

      true ->
        family = Balance.family(Keyword.get(opts, :path))

        case Balance.check(content, open, close, family) do
          {:ok, report} -> {:ok, content, report}
          {:error, report} -> {:error, report}
        end
    end
  end

  defp apply_one(_content, op, _opts), do: {:error, "malformed operation #{inspect(op)}"}

  # ── Helpers ───────────────────────────────────────────────────────────

  defp insert(content, op, pattern, text, position) do
    with {:ok, re} <- compile(pattern) do
      {lines, eol} = split_lines(content)
      matched = Enum.count(lines, &Regex.match?(re, &1))

      with :ok <- check_count(op, matched, "matching lines") do
        inserted = String.split(text, ~r/\r?\n/)

        out =
          Enum.flat_map(lines, fn line ->
            if Regex.match?(re, line) do
              case position do
                :after -> [line | inserted]
                :before -> inserted ++ [line]
              end
            else
              [line]
            end
          end)

        {:ok, join_lines(out, eol), "inserted at #{matched} site(s)"}
      end
    end
  end

  defp compile(pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> {:ok, re}
      {:error, reason} -> {:error, "invalid regex #{inspect(pattern)}: #{inspect(reason)}"}
    end
  end

  # A zero-match mutation is ALWAYS an error, expectation or not. Silently
  # doing nothing and reporting success is how a model concludes an edit landed
  # and builds three more edits on top of it.
  defp check_count(op, count, noun) do
    case Map.get(op, "expect") do
      nil when count > 0 ->
        :ok

      nil ->
        {:error,
         "found 0 #{noun}. The anchor is not in the file, so nothing was written. " <>
           "Check the anchor with an `op: \"count\"` operation, or widen it."}

      n when n == count ->
        :ok

      n ->
        {:error,
         "expected #{n} #{noun}, found #{count}. Nothing was written. " <>
           "Either the file is not what you expected or the anchor is too " <>
           "#{if count > n, do: "loose", else: "specific"}."}
    end
  end

  # Preserve the file's dominant line ending, and whether it ended with one.
  defp split_lines(content) do
    eol = if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
    trailing? = String.ends_with?(content, eol)

    lines =
      content
      |> String.split(eol)
      |> then(fn parts -> if trailing?, do: Enum.drop(parts, -1), else: parts end)

    {lines, {eol, trailing?}}
  end

  defp join_lines(lines, {eol, trailing?}) do
    joined = Enum.join(lines, eol)
    if trailing? and joined != "", do: joined <> eol, else: joined
  end
end
