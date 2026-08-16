defmodule OptimalSystemAgent.Agent.Loop.ToolArgMetrics do
  @moduledoc """
  Honest, analysis-grade measurements of a tool call's arguments: how many
  bytes the model actually emitted, and a stable identity for detecting
  repeats.

  ## Why this exists as a separate thing from `Loop.ToolHint`

  `ToolHint.summarize/1` is a DISPLAY string. It clips a shell command at 60
  characters (`ToolHint` :85) and reduces every file tool to its bare path
  (:80-82), deliberately, because that is what fits in a TUI cell. It was
  also, for a while, the only argument-shaped field on the `:tool_call` event
  — so every behavioural analysis of OSA read it as if it were the arguments.

  Two published comparisons against competitor harnesses were built on that
  field, and both were artifacts of the clip:

    * **"OSA's median tool-call argument is 62 bytes, against codex's 286."**
      Across the 361 calls of the `h2h-1` head-to-head, `shell_execute` shows
      a maximum argument of exactly 60 bytes and `file_write` a maximum of 30
      — a 7 KB file write was recorded as `"eval.scm"`. The competitor arms
      were counted from ATIF trajectories carrying full arguments. The two
      numbers never described the same quantity.

    * **"43.5% duplicate tool calls, against codex's 0.7%."** Hashing the hint
      collapses calls that differ only in a clipped field. 49 `file_read`
      calls reading 49 different offset windows of one growing file hash
      identically once `offset`/`limit` are dropped. Re-measured against real
      arguments, `schemelike-metacircular-eval` has 26 exact repeats (9.4%),
      and none of them is a `file_read`.

  Both fields below are emitted alongside the hint rather than replacing it,
  so the TUI keeps the string it was designed around and analysis gets fields
  that mean what the competitors' fields mean.

  Nothing here is on a hot path in any interesting sense — one JSON encode and
  one SHA-256 per tool call, against a call that is about to do I/O.

  ## `assertion_lines/1` — the fact species 2 needs and the log did not carry

  `docs/research/failure-taxonomy.md` §2.5 records a hard artefact limit:

  > OSA's event log stores a `file_write`'s path but not its content, and
  > `tool_call.args` is clipped at 60 bytes. No replay over this run can
  > compare what a test *asserted* against what the task *required*, which is
  > the only comparison that separates these nine from the solves.

  Thirty candidate detectors have now been rejected against species 2 — twelve
  in §2.4/§2.5 and eighteen more in `docs/design/iteration-discipline.md` —
  and every one of them was a *shape* proxy standing in for that missing
  content. `assertion_lines/1` records the content instead: the assertion
  statements of what the model wrote, verbatim, on the `:tool_call` event.

  It is pure instrumentation. It gates nothing, it costs the model no turns,
  and it can therefore not fire on a solve. What it buys is that the next
  species-2 question is answerable by reading the log rather than by inventing
  a thirty-first proxy. `OSA_ASSERTION_CAPTURE=0` removes it.
  """

  @hash_prefix_bytes 16

  # Assertion-bearing statement forms across the languages this benchmark
  # corpus actually writes tests in. Anchored on a non-word boundary so
  # `reassert_all` and a prose line containing "expected" do not match.
  #
  #   * `assert` — Python (`assert`, `self.assertEqual`), C/C++ (`assert(`),
  #     Rust (`assert!`, `assert_eq!`), JS (`assert.strictEqual`).
  #   * `EXPECT_` / `ASSERT_` — googletest.
  #   * `expect(` — jest / chai / vitest.
  #   * `t.Error` / `t.Fatal` — Go, which has no assert keyword and whose
  #     failure statement IS the assertion.
  #   * `require.` / `assert.` — testify.
  @assertion_re ~r/(^|[^\w.])(assert\w*|EXPECT_\w+|ASSERT_\w+|expect\s*\(|t\.(Error|Fatal)f?\s*\(|require\.\w+)/

  # Per-line clip. Long enough to carry an assertion and its message, short
  # enough that a minified or generated line cannot dominate the event.
  @assertion_line_chars 240

  # Per-call cap. A test file with more assertions than this is described by
  # its first `@max_assertion_lines`; the count is not the interesting part,
  # the propositions are, and they repeat.
  @max_assertion_lines 12

  # Scan ceiling. `file_write` payloads in the corpus run to ~8 KB; this is an
  # order of magnitude of headroom and a hard stop against a pathological
  # single write on the telemetry path.
  @max_scan_bytes 262_144

  @doc """
  Byte size of the arguments as JSON — the same quantity a competitor's
  trajectory reports as its tool-call argument size.

  Falls back to `inspect/1` for a term Jason cannot encode, so this never
  raises on the telemetry path and never returns a misleading zero for a
  non-empty argument map.
  """
  @spec arg_bytes(any()) :: non_neg_integer()
  def arg_bytes(args) when is_binary(args), do: byte_size(args)

  def arg_bytes(args) when is_map(args) or is_list(args) do
    case Jason.encode(args) do
      {:ok, json} -> byte_size(json)
      _ -> args |> inspect() |> byte_size()
    end
  end

  def arg_bytes(nil), do: 0
  def arg_bytes(other), do: other |> inspect() |> byte_size()

  @doc """
  A stable 32-hex-character identity for the FULL arguments, for duplicate
  detection.

  Key duplicate analysis on `{tool_name, arg_hash}`. Never on
  `{tool_name, args}`, where `args` is the display hint — that is the mistake
  this module documents.

  Map keys are sorted recursively before encoding: `Jason` does not guarantee
  key order for a map, so without canonicalisation two identical calls could
  hash differently and a duplicate would read as novel work.
  """
  @spec arg_hash(any()) :: String.t()
  def arg_hash(args) do
    payload =
      case args |> canonicalize() |> Jason.encode() do
        {:ok, json} -> json
        _ -> inspect(args)
      end

    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_prefix_bytes * 2)
  end

  @doc """
  The assertion statements carried by a write tool's payload, or `nil`.

  Reads `"content"` (`file_write`, `file_transform`) and `"new_string"`
  (`file_edit`, `multi_file_edit`) — the two keys through which every
  assertion OSA has ever written reached disk. Any other argument shape
  returns `nil`, so shell commands, reads and searches are untouched.

  `nil` rather than `[]` when nothing matches: an absent field reads as "this
  call carried no assertions", which is what it means, and keeps the event
  unchanged for the overwhelming majority of calls.

  Deliberately NOT a judgement. It does not decide whether the assertions are
  adequate, whether they correspond to the task, or whether they are a test at
  all — a `file_write` of production code containing `assert(ptr != NULL)`
  will be recorded, correctly, as a line containing an assertion. Every attempt
  so far to turn a shape like this into a verdict has been rejected under the
  `scripts/failure_species.py` acceptance rule; this one stays a measurement.
  """
  @spec assertion_lines(any()) :: [String.t()] | nil
  def assertion_lines(args) do
    if capture_enabled?() do
      args |> written_text() |> extract_assertions()
    else
      nil
    end
  end

  defp written_text(%{"content" => c}) when is_binary(c), do: c
  defp written_text(%{"new_string" => c}) when is_binary(c), do: c
  defp written_text(_), do: nil

  defp extract_assertions(nil), do: nil

  defp extract_assertions(text) do
    text
    |> binary_slice(0, @max_scan_bytes)
    |> String.split(["\r\n", "\n"])
    |> Stream.filter(&Regex.match?(@assertion_re, &1))
    |> Stream.map(&normalize_line/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.take(@max_assertion_lines)
    |> case do
      [] -> nil
      lines -> lines
    end
  end

  # Leading indentation and internal runs of whitespace collapse, so the same
  # assertion written at two nesting depths compares equal across trials.
  defp normalize_line(line) do
    line
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @assertion_line_chars)
  end

  defp capture_enabled? do
    case System.get_env("OSA_ASSERTION_CAPTURE") do
      v when v in ["0", "false", "off", "no"] ->
        false

      _ ->
        Application.get_env(:optimal_system_agent, :assertion_capture, true) != false
    end
  end

  # Maps become sorted {key, value} lists so encoding order is total. Every
  # key is stringified first, so `%{"a" => 1}` and `%{a: 1}` — the same call
  # arriving through two decode paths — agree.
  defp canonicalize(%{} = map) when not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> [to_string(k), canonicalize(v)] end)
    |> Enum.sort_by(&hd/1)
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other
end
