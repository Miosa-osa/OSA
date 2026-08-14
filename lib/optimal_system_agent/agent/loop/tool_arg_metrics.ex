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
  """

  @hash_prefix_bytes 16

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
