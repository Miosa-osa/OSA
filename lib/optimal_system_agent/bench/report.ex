defmodule OptimalSystemAgent.Bench.Report do
  @moduledoc """
  Result files, the compact results table, and before/after comparison.

  A result file is one JSON document (`schema: "osa-bench/1"`) holding the run's
  metadata, one row per task attempt, and a summary. Rows keep the full
  `/trace` summary of their turn so a surprising number can be inspected after
  the fact without re-running anything.
  """

  alias OptimalSystemAgent.Agent.TurnTrace

  @schema "osa-bench/1"

  @metric_keys ~w(wall_ms model_ms tool_ms approval_ms background_ms other_ms llm_calls
                  tool_calls tokens_in tokens_out cache_read_tokens cost_usd retries
                  wasted_steps wasted_ms)a

  @doc "Assemble the result document for a finished run."
  @spec document(map(), [map()]) :: map()
  def document(meta, rows) do
    Map.merge(meta, %{schema: @schema, tasks: rows, summary: summary(rows)})
  end

  @doc "Totals and pass rate across every row of a run."
  @spec summary([map()]) :: map()
  def summary(rows) do
    per_task = aggregate(rows)
    passed = Enum.count(per_task, &(&1.pass_rate == 1.0))
    attempts_passed = Enum.count(rows, &(get(&1, :pass) == true))

    totals =
      Map.new(@metric_keys, fn k ->
        {k, rows |> Enum.map(&get(&1, k)) |> Enum.filter(&is_number/1) |> Enum.sum()}
      end)

    %{
      tasks: length(per_task),
      attempts: length(rows),
      passed_tasks: passed,
      attempts_passed: attempts_passed,
      pass_rate: ratio(attempts_passed, length(rows)),
      totals: Map.update!(totals, :cost_usd, &Float.round(&1 * 1.0, 6))
    }
  end

  @doc """
  One entry per task: pass rate across attempts and the MEDIAN of every metric
  (robust to one slow attempt on a live provider).
  """
  @spec aggregate([map()]) :: [map()]
  def aggregate(rows) do
    rows
    |> Enum.group_by(&get(&1, :id))
    |> Enum.map(fn {id, attempts} ->
      medians =
        Map.new(@metric_keys, fn k ->
          {k, attempts |> Enum.map(&get(&1, k)) |> Enum.filter(&is_number/1) |> median()}
        end)

      Map.merge(medians, %{
        id: id,
        category: get(hd(attempts), :category),
        attempts: length(attempts),
        passes: Enum.count(attempts, &(get(&1, :pass) == true)),
        pass_rate: ratio(Enum.count(attempts, &(get(&1, :pass) == true)), length(attempts)),
        par_tool_calls: get(hd(attempts), :par_tool_calls),
        status: attempts |> Enum.map(&get(&1, :status)) |> Enum.uniq() |> Enum.join("/")
      })
    end)
    |> Enum.sort_by(& &1.id)
  end

  # Rows are atom-keyed in memory and string-keyed once read back from JSON.
  defp get(row, key), do: Map.get(row, key, Map.get(row, Atom.to_string(key)))

  # ── files ────────────────────────────────────────────────────────────

  @doc "Write the result document as pretty JSON."
  @spec write!(Path.t(), map()) :: :ok
  def write!(path, doc) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(doc, pretty: true))
    :ok
  end

  @doc "Read a result document; rows come back string-keyed."
  @spec read(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"schema" => @schema} = doc} <- Jason.decode(body) do
      {:ok, doc}
    else
      {:ok, _} -> {:error, "#{path} is not an osa-bench result file"}
      {:error, %Jason.DecodeError{}} -> {:error, "#{path} is not valid JSON"}
      {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
    end
  end

  # ── table ────────────────────────────────────────────────────────────

  @doc "The compact results table for a run's rows."
  @spec table([map()]) :: String.t()
  def table(rows) do
    per_task = aggregate(rows)
    width = per_task |> Enum.map(&String.length(&1.id)) |> Enum.max(fn -> 4 end) |> max(4)

    header =
      pad("task", width) <>
        "  " <>
        pad("ok", 5) <>
        lpad("wall", 8) <>
        lpad("model", 8) <>
        lpad("tools", 8) <>
        lpad("calls/par", 10) <>
        lpad("tok in/out", 14) <> lpad("cost", 9) <> lpad("retry", 6) <> lpad("waste", 6)

    lines =
      Enum.map(per_task, fn t ->
        ok =
          cond do
            t.attempts > 1 -> "#{t.passes}/#{t.attempts}"
            t.pass_rate == 1.0 -> "pass"
            true -> "FAIL"
          end

        pad(t.id, width) <>
          "  " <>
          pad(ok, 5) <>
          lpad(ms(t.wall_ms), 8) <>
          lpad(ms(t.model_ms), 8) <>
          lpad(ms(t.tool_ms), 8) <>
          lpad("#{n(t.tool_calls)}/#{t.par_tool_calls}", 10) <>
          lpad("#{tok(t.tokens_in)}/#{tok(t.tokens_out)}", 14) <>
          lpad(usd(t.cost_usd), 9) <> lpad(n(t.retries), 6) <> lpad(n(t.wasted_steps), 6)
      end)

    s = summary(rows)
    tot = s.totals

    footer =
      "#{s.passed_tasks}/#{s.tasks} tasks passed" <>
        if(s.attempts > s.tasks, do: " (#{s.attempts_passed}/#{s.attempts} attempts)", else: "") <>
        " · wall #{ms(tot.wall_ms)} · model #{ms(tot.model_ms)} · tools #{ms(tot.tool_ms)}" <>
        " · #{tok(tot.tokens_in)} in / #{tok(tot.tokens_out)} out · #{usd(tot.cost_usd)}" <>
        " · #{tot.tool_calls} tool calls · #{tot.retries} retries · #{tot.wasted_steps} wasted"

    failures =
      rows
      |> Enum.reject(&(get(&1, :pass) == true))
      |> Enum.map(fn r ->
        why =
          get(r, :error) ||
            (get(r, :checks) || [])
            |> Enum.reject(&(get(&1, :pass) == true))
            |> Enum.map_join("; ", &get(&1, :detail))

        "  #{get(r, :id)}##{get(r, :attempt)}: #{String.slice(to_string(why), 0, 160)}"
      end)

    Enum.join(
      [header | lines] ++
        ["", footer] ++ if(failures == [], do: [], else: ["", "failures:" | failures]),
      "\n"
    )
  end

  # ── compare ──────────────────────────────────────────────────────────

  @doc """
  Per-task before/after comparison of two result documents (as read by
  `read/1`). Returns `%{rows: [...], summary: %{...}, text: table}`.

  A task that passed in `a` and failed in `b` is a REGRESSION; the reverse is
  FIXED. Metric deltas are medians over each side's attempts. `geo_wall_ratio`
  is the geometric mean of per-task wall-time ratios b/a over tasks both sides
  passed - the one number to quote for "faster or slower", because a sum is
  dominated by the slowest task.
  """
  @spec compare(map(), map()) :: map()
  def compare(a, b) do
    ra = a |> Map.get("tasks", []) |> aggregate() |> Map.new(&{&1.id, &1})
    rb = b |> Map.get("tasks", []) |> aggregate() |> Map.new(&{&1.id, &1})
    ids = (Map.keys(ra) ++ Map.keys(rb)) |> Enum.uniq() |> Enum.sort()

    rows =
      Enum.map(ids, fn id ->
        x = Map.get(ra, id)
        y = Map.get(rb, id)

        verdict =
          cond do
            is_nil(x) -> "new"
            is_nil(y) -> "gone"
            x.pass_rate == 1.0 and y.pass_rate < 1.0 -> "REGRESSED"
            x.pass_rate < 1.0 and y.pass_rate == 1.0 -> "FIXED"
            true -> ""
          end

        %{id: id, a: x, b: y, verdict: verdict}
      end)

    both_passed =
      Enum.filter(rows, &(&1.a && &1.b && &1.a.pass_rate == 1.0 && &1.b.pass_rate == 1.0))

    ratios =
      both_passed
      |> Enum.map(fn r -> {r.a.wall_ms, r.b.wall_ms} end)
      |> Enum.filter(fn {x, y} -> is_number(x) and is_number(y) and x > 0 and y > 0 end)
      |> Enum.map(fn {x, y} -> y / x end)

    sa = summary_of(a)
    sb = summary_of(b)

    summary = %{
      a: %{label: label(a), passed: sa.passed, tasks: sa.tasks, totals: sa.totals},
      b: %{label: label(b), passed: sb.passed, tasks: sb.tasks, totals: sb.totals},
      regressed: rows |> Enum.filter(&(&1.verdict == "REGRESSED")) |> Enum.map(& &1.id),
      fixed: rows |> Enum.filter(&(&1.verdict == "FIXED")) |> Enum.map(& &1.id),
      geo_wall_ratio: geo_mean(ratios),
      compared_for_speed: length(ratios)
    }

    %{rows: rows, summary: summary, text: compare_text(rows, summary)}
  end

  defp summary_of(doc) do
    per_task = doc |> Map.get("tasks", []) |> aggregate()

    totals =
      Map.new(
        ~w(wall_ms model_ms tool_ms tokens_in tokens_out cost_usd tool_calls retries wasted_steps)a,
        fn k ->
          {k, per_task |> Enum.map(&Map.get(&1, k)) |> Enum.filter(&is_number/1) |> Enum.sum()}
        end
      )

    %{
      passed: Enum.count(per_task, &(&1.pass_rate == 1.0)),
      tasks: length(per_task),
      totals: totals
    }
  end

  defp label(doc) do
    [doc["git_sha"], doc["model"] || doc["control"], doc["run_id"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp compare_text(rows, s) do
    width = rows |> Enum.map(&String.length(&1.id)) |> Enum.max(fn -> 4 end) |> max(4)

    header =
      pad("task", width) <>
        "  " <>
        pad("ok a>b", 11) <>
        lpad("wall a>b", 18) <>
        lpad("tokens a>b", 20) <> lpad("calls", 8) <> lpad("cost a>b", 20) <> "  note"

    lines =
      Enum.map(rows, fn %{id: id, a: x, b: y, verdict: v} ->
        pad(id, width) <>
          "  " <>
          pad("#{okc(x)}>#{okc(y)}", 11) <>
          lpad(delta(x, y, :wall_ms, &ms/1), 18) <>
          lpad(delta_tokens(x, y), 20) <>
          lpad("#{calls(x)}>#{calls(y)}", 8) <>
          lpad(delta(x, y, :cost_usd, &usd/1), 20) <> "  " <> v
      end)

    ta = s.a.totals
    tb = s.b.totals

    footer = [
      "",
      "a: #{s.a.label}",
      "b: #{s.b.label}",
      "passed      #{s.a.passed}/#{s.a.tasks} > #{s.b.passed}/#{s.b.tasks}",
      "wall        #{ms(ta.wall_ms)} > #{ms(tb.wall_ms)} (#{pct(ta.wall_ms, tb.wall_ms)})",
      "model       #{ms(ta.model_ms)} > #{ms(tb.model_ms)} (#{pct(ta.model_ms, tb.model_ms)})",
      "tools       #{ms(ta.tool_ms)} > #{ms(tb.tool_ms)} (#{pct(ta.tool_ms, tb.tool_ms)})",
      "tokens in   #{tok(ta.tokens_in)} > #{tok(tb.tokens_in)} (#{pct(ta.tokens_in, tb.tokens_in)})",
      "tokens out  #{tok(ta.tokens_out)} > #{tok(tb.tokens_out)} (#{pct(ta.tokens_out, tb.tokens_out)})",
      "cost        #{usd(ta.cost_usd)} > #{usd(tb.cost_usd)} (#{pct(ta.cost_usd, tb.cost_usd)})",
      "tool calls  #{ta.tool_calls} > #{tb.tool_calls}   retries #{ta.retries} > #{tb.retries}" <>
        "   wasted #{ta.wasted_steps} > #{tb.wasted_steps}",
      "speed       " <>
        case s.geo_wall_ratio do
          nil ->
            "n/a (no task passed on both sides)"

          r ->
            "b takes #{:erlang.float_to_binary(r, decimals: 2)}x the wall time of a " <>
              "(geometric mean over #{s.compared_for_speed} tasks passed on both sides)"
        end
    ]

    footer =
      footer ++
        if(s.regressed == [], do: [], else: ["REGRESSED: " <> Enum.join(s.regressed, ", ")]) ++
        if s.fixed == [], do: [], else: ["fixed: " <> Enum.join(s.fixed, ", ")]

    Enum.join([header | lines] ++ footer, "\n")
  end

  defp okc(nil), do: "-"
  defp okc(%{attempts: 1, pass_rate: 1.0}), do: "pass"
  defp okc(%{attempts: 1}), do: "FAIL"
  defp okc(%{passes: p, attempts: n}), do: "#{p}/#{n}"

  defp calls(nil), do: "-"
  defp calls(t), do: n(t.tool_calls)

  defp delta(nil, _, _, _), do: "-"
  defp delta(_, nil, _, _), do: "-"

  defp delta(x, y, key, fmt) do
    a = Map.get(x, key)
    b = Map.get(y, key)
    "#{fmt.(a)}>#{fmt.(b)} #{pct(a, b)}"
  end

  defp delta_tokens(nil, _), do: "-"
  defp delta_tokens(_, nil), do: "-"

  defp delta_tokens(x, y) do
    a = sum_nil(x.tokens_in, x.tokens_out)
    b = sum_nil(y.tokens_in, y.tokens_out)
    "#{tok(a)}>#{tok(b)} #{pct(a, b)}"
  end

  defp sum_nil(a, b) when is_number(a) and is_number(b), do: a + b
  defp sum_nil(_, _), do: nil

  defp pct(a, b) when is_number(a) and is_number(b) and a > 0 do
    d = round((b - a) * 100 / a)
    if d > 0, do: "+#{d}%", else: "#{d}%"
  end

  defp pct(_, _), do: ""

  defp geo_mean([]), do: nil

  defp geo_mean(ratios) do
    ratios |> Enum.map(&:math.log/1) |> Enum.sum() |> Kernel./(length(ratios)) |> :math.exp()
  end

  # ── formatting ───────────────────────────────────────────────────────

  defp median([]), do: nil

  defp median(list) do
    sorted = Enum.sort(list)
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp ratio(_, 0), do: 0.0
  defp ratio(a, b), do: Float.round(a / b, 4)

  defp ms(nil), do: "-"
  defp ms(v) when is_float(v), do: ms(round(v))
  defp ms(v), do: TurnTrace.secs(v)

  defp n(nil), do: "-"
  defp n(v) when is_float(v), do: v |> round() |> Integer.to_string()
  defp n(v), do: to_string(v)

  defp tok(nil), do: "-"
  defp tok(v) when v >= 1000, do: "#{:erlang.float_to_binary(v / 1000, decimals: 1)}k"
  defp tok(v), do: v |> round() |> Integer.to_string()

  defp usd(nil), do: "-"
  defp usd(v) when v == 0, do: "$0"
  defp usd(v), do: "$" <> :erlang.float_to_binary(v * 1.0, decimals: 4)

  defp pad(s, w), do: String.pad_trailing(s, w)
  defp lpad(s, w), do: String.pad_leading(s, w)
end
