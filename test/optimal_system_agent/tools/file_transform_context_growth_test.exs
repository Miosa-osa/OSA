defmodule OptimalSystemAgent.Tools.FileTransformContextGrowthTest do
  @moduledoc """
  The measurement the whole design rests on.

  The claim is not "file_transform produces smaller tool calls". It is that
  **`file_edit`'s context cost is O(edits x filesize) and `file_transform`'s is
  O(edits)** — a difference in shape, not in constant factor. A difference in
  shape is demonstrated by varying the file size and showing that one curve
  moves and the other does not, so that is what this test does. Anything less
  would be an assertion with a number next to it.

  ## What is counted

  For each edit, the bytes that actually enter the model's context:

    * the JSON encoding of the tool-call arguments the model must emit, and
    * the tool result string the model receives back.

  Plus, for `file_edit` only, the `file_read` that read-before-edit requires:
  its arguments and — the dominant term — the file it returns. Two `file_edit`
  regimes are measured, because the harness currently supports both and they
  bracket the truth:

    * `read-once` — one read before the first edit. The rule the correction to
      `turn-count-diagnosis.md` recommends, and the best case for `file_edit`.
    * `read-each` — a read before every edit. The rhythm actually measured on
      `schemelike-metacircular-eval`, where `FileState.record_write/2` drops the
      recorded ranges after each write and read-before-edit then makes the next
      read mandatory.

  `file_transform` needs no read in either regime, which is the point.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: EditHandler
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: ReadHandler
  alias OptimalSystemAgent.Tools.Builtins.FileTransform.Handler, as: TransformHandler

  # codex made 12 write operations on the artefact it solved. Same N here.
  @edits 12

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_ft_growth_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # ── The corpus ────────────────────────────────────────────────────────

  # A file with `n` uniquely-named definitions, shaped like the Scheme
  # metacircular evaluator the head-to-head was run on: every edit target is
  # unique, so `file_edit` never needs a larger `old_string` than one line, and
  # the comparison is as generous to `file_edit` as it can honestly be.
  defp corpus(n) do
    1..n
    |> Enum.map_join("\n", fn i ->
      """
      (define (helper-#{i} x env)
        (cond ((self-evaluating? x) x)
              ((variable? x) (lookup-variable-value x env))
              (else (error "Unknown expression type -- HELPER#{i}" x))))
      """
    end)
  end

  defp write_corpus(dir, name, n) do
    path = Path.join(dir, name)
    File.write!(path, corpus(n))
    path
  end

  # ── Cost accounting ───────────────────────────────────────────────────

  defp args_bytes(args), do: args |> Jason.encode!() |> byte_size()

  defp result_bytes({:ok, text}) when is_binary(text), do: byte_size(text)
  defp result_bytes({:ok, text, _meta}) when is_binary(text), do: byte_size(text)
  defp result_bytes({:error, text}) when is_binary(text), do: byte_size(text)

  defp call(handler, args, ctx), do: args_bytes(args) + result_bytes(handler.execute(args, ctx))

  defp ctx(tag), do: %{session_id: "growth-#{tag}-#{:erlang.unique_integer([:positive])}"}

  # ── The three regimes ─────────────────────────────────────────────────

  defp transform_cost(path, n_edits) do
    c = ctx("transform")

    Enum.reduce(1..n_edits, 0, fn i, acc ->
      args = %{
        "path" => path,
        "operations" => [
          %{
            "op" => "replace",
            "find" => "HELPER#{i}\"",
            "to" => "HELPER-#{i}-CHECKED\"",
            "expect" => 1
          }
        ]
      }

      acc + call(TransformHandler, args, c)
    end)
  end

  defp edit_cost(path, n_edits, regime) do
    c = ctx("edit")
    read_args = %{"path" => path}

    initial = if regime == :read_once, do: call(ReadHandler, read_args, c), else: 0

    Enum.reduce(1..n_edits, initial, fn i, acc ->
      read = if regime == :read_each, do: call(ReadHandler, read_args, c), else: 0

      # `file_edit` must quote bytes that are actually in the file. One line is
      # the smallest unique anchor available here.
      old = ~s|        (else (error "Unknown expression type -- HELPER#{i}" x))))|
      new = ~s|        (else (error "Unknown expression type -- HELPER-#{i}-CHECKED" x))))|

      args = %{"path" => path, "old_string" => old, "new_string" => new}
      acc + read + call(EditHandler, args, c)
    end)
  end

  # ── The measurement ───────────────────────────────────────────────────

  test "context cost of N edits is flat in file size for file_transform and linear for file_edit",
       ctx do
    sizes = [50, 200, 800]

    rows =
      for defs <- sizes do
        t_path = write_corpus(ctx.dir, "t_#{defs}.scm", defs)
        o_path = write_corpus(ctx.dir, "o_#{defs}.scm", defs)
        e_path = write_corpus(ctx.dir, "e_#{defs}.scm", defs)
        bytes = File.stat!(t_path).size

        %{
          defs: defs,
          file_bytes: bytes,
          transform: transform_cost(t_path, @edits),
          edit_read_once: edit_cost(o_path, @edits, :read_once),
          edit_read_each: edit_cost(e_path, @edits, :read_each)
        }
      end

    report(rows)

    small = hd(rows)
    large = List.last(rows)

    # 1. The file grew by ~16x across the sweep.
    growth = large.file_bytes / small.file_bytes
    assert growth > 10

    # 2. file_transform's cost is FLAT: it does not track file size at all. The
    #    small residual is the per-call path string and the reported byte/line
    #    counts getting one digit longer.
    transform_ratio = large.transform / small.transform

    assert transform_ratio < 1.2,
           "file_transform cost grew #{Float.round(transform_ratio, 2)}x for a " <>
             "#{Float.round(growth, 1)}x larger file — it should be flat"

    # 3. file_edit's cost tracks the file, even in its best regime, because the
    #    read that read-before-edit requires returns the whole file.
    edit_ratio = large.edit_read_once / small.edit_read_once

    assert edit_ratio > 5,
           "file_edit (read-once) cost grew only #{Float.round(edit_ratio, 2)}x — " <>
             "the O(filesize) term is expected to dominate"

    # 4. And in the regime actually measured on the benchmark, it is ~N times worse.
    assert large.edit_read_each > large.edit_read_once * 5

    # 5. The headline: on the largest file, the same twelve edits.
    assert large.transform * 20 < large.edit_read_once
  end

  test "one probe costs the same on a large file as on a small one", ctx do
    small = write_corpus(ctx.dir, "p_small.scm", 50)
    large = write_corpus(ctx.dir, "p_large.scm", 800)
    c = ctx("probe")

    probe = fn path ->
      call(TransformHandler, %{"path" => path, "operations" => [%{"op" => "assert_balanced"}]}, c)
    end

    # The competing way to answer "is this file well-formed" is to read it.
    read = fn path -> call(ReadHandler, %{"path" => path}, c) end

    p_small = probe.(small)
    p_large = probe.(large)
    r_large = read.(large)

    IO.puts("""

    Answering "is this file balanced?" on a #{File.stat!(large).size}-byte file
      file_transform assert_balanced : #{p_large} bytes of context
      file_read (the alternative)    : #{r_large} bytes of context
      same probe on a #{File.stat!(small).size}-byte file : #{p_small} bytes
    """)

    assert p_large - p_small < 20
    assert r_large > p_large * 50
  end

  defp report(rows) do
    IO.puts("""

    Bytes of context to make #{@edits} edits to ONE file
    (tool-call arguments + tool results, as they enter the model's context)

    | defs | file bytes | file_transform | file_edit (read once) | file_edit (read each) |
    |-----:|-----------:|---------------:|----------------------:|----------------------:|\
    """)

    Enum.each(rows, fn r ->
      IO.puts(
        "| #{pad(r.defs, 4)} | #{pad(r.file_bytes, 10)} | #{pad(r.transform, 14)} " <>
          "| #{pad(r.edit_read_once, 21)} | #{pad(r.edit_read_each, 21)} |"
      )
    end)

    IO.puts("")
  end

  defp pad(n, w), do: n |> to_string() |> String.pad_leading(w)
end
