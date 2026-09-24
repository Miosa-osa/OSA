defmodule OptimalSystemAgent.Agent.TurnTrace do
  @moduledoc """
  Per-turn timing record: where the time of one turn went.

  Answers "why was that turn slow?" with measured numbers instead of a guess:
  model time, tool time (per tool, with the slowest calls), time waiting on the
  user's approval, time waiting on background work, retries/recoveries, and
  "wasted" steps (an identical read-only probe repeated with nothing written in
  between).

  ## Where the numbers come from

  Every figure is recorded at the point the daemon already measures it, not
  re-derived from the event bus (whose handlers run in unordered tasks and can
  lag the turn they describe):

    * `record_llm/2` - `ReactLoop`, beside the `:llm_response` emit, with the
      same `duration_ms` and usage map, plus the cost delta `Accounting.record/3`
      just added to the session.
    * `record_tool/2` - `ToolExecutor.finalize_result/5`, beside the
      `:tool_call` `phase: :end` emit, with the same `duration_ms`.
    * `record_approval_wait/2` - `ToolExecutor.await_permission/4`, around the
      `PermissionBroker.await/3` park. That wait is INSIDE the tool's duration,
      so the summary subtracts it from tool time.
    * `record_recovery/3` - every loop recovery (`ReactLoop.spend_recovery/2`),
      provider retries/fallbacks bridged by `LLMClient`, and `ToolRetry`.
    * `begin_turn/2` / `end_turn/2` - `Loop.handle_call({:process, ...})` and the
      idle-poke synthetic turn.

  ## Storage

  Two public ETS tables created at boot (`init_tables/0`): a `:set` of per-turn
  metadata and a `:duplicate_bag` of event rows. Concurrent tool tasks insert
  rows without a read-modify-write, so parallel calls never race each other.
  Only the last 5 turns of a session are kept. Every write is best-effort:
  a missing table or a bad value never reaches the turn.
  """

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.ReadOnly

  @meta :osa_turn_trace_meta
  @events :osa_turn_trace_events
  @keep_turns 5

  # Tools whose whole purpose is to wait for work running elsewhere (a
  # background shell, a delegated task, a pty). Their time is reported as
  # "background", not as tool work.
  @background_wait_tools ~w(task_wait task_output bash_output pty_wait sleep monitor)

  # Tools that never change anything. Repeating one of these with identical
  # arguments, with no write in between, re-reads a fact already in context.
  @read_only_tools ~w(
    file_read file_grep file_glob dir_list code_symbols codebase_explore
    semantic_search session_search memory_recall tool_search web_search web_fetch
    list_agents list_skills workspace_map skill_view find_skill
  )

  @type summary :: map()

  # ── Setup ────────────────────────────────────────────────────────────

  @doc "Create the trace tables. Called once at boot; idempotent."
  @spec init_tables() :: :ok
  def init_tables do
    ensure(@meta, [:named_table, :public, :set, read_concurrency: true])
    ensure(@events, [:named_table, :public, :duplicate_bag, write_concurrency: true])
    :ok
  end

  defp ensure(name, opts) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _ -> name
    end
  rescue
    ArgumentError -> name
  end

  # ── Turn boundaries ──────────────────────────────────────────────────

  @doc """
  Open a new turn for `session_id`. `attrs` may carry `:model`, `:provider` and
  `:prompt` (only a short preview is kept).
  """
  @spec begin_turn(String.t(), map()) :: :ok
  def begin_turn(session_id, attrs \\ %{})

  def begin_turn(session_id, attrs) when is_binary(session_id) do
    turn =
      case :ets.lookup(@meta, session_id) do
        [{^session_id, %{turn: n}}] -> n + 1
        _ -> 1
      end

    meta = %{
      turn: turn,
      status: :running,
      started_mono: now(),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      ended_mono: nil,
      model: attrs |> Map.get(:model) |> string_or_nil(),
      provider: attrs |> Map.get(:provider) |> string_or_nil(),
      prompt: attrs |> Map.get(:prompt) |> preview(80),
      history: history_after_begin(session_id, turn)
    }

    :ets.insert(@meta, {session_id, meta})
    :ok
  rescue
    _ -> :ok
  end

  def begin_turn(_, _), do: :ok

  # The metadata row holds the current turn; finished turns ride in its
  # `history` (newest first) so `turns/1` can show the last few. Events of turns
  # that fall off the end are deleted here, which bounds the table.
  defp history_after_begin(session_id, turn) do
    previous =
      case :ets.lookup(@meta, session_id) do
        [{^session_id, meta}] -> [Map.delete(meta, :history) | Map.get(meta, :history, [])]
        _ -> []
      end

    {kept, dropped} = Enum.split(previous, @keep_turns - 1)
    Enum.each(dropped, fn %{turn: n} -> :ets.delete(@events, {session_id, n}) end)
    # A stale row for this turn number (a restarted daemon never has one, but a
    # reused session id in tests can) must not leak into the new turn.
    :ets.delete(@events, {session_id, turn})
    kept
  end

  @doc "Close the current turn of `session_id`."
  @spec end_turn(String.t(), atom()) :: :ok
  def end_turn(session_id, status \\ :done)

  def end_turn(session_id, status) when is_binary(session_id) do
    case :ets.lookup(@meta, session_id) do
      [{^session_id, %{ended_mono: nil} = meta}] ->
        :ets.insert(@meta, {session_id, %{meta | ended_mono: now(), status: status}})

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def end_turn(_, _), do: :ok

  # ── Recording ────────────────────────────────────────────────────────

  @doc """
  One completed (or failed) model round-trip. Keys: `:duration_ms`, `:model`,
  `:usage` (the provider's usage map), `:cost_usd`, `:ok`.
  """
  @spec record_llm(String.t(), map()) :: :ok
  def record_llm(session_id, attrs) when is_map(attrs) do
    usage = Map.get(attrs, :usage) || %{}

    put(session_id, :llm, %{
      duration_ms: int(Map.get(attrs, :duration_ms)),
      model: string_or_nil(Map.get(attrs, :model)),
      input_tokens: int(Map.get(usage, :input_tokens)),
      output_tokens: int(Map.get(usage, :output_tokens)),
      cache_read_tokens: int(Map.get(usage, :cache_read_tokens)),
      cost_usd: num(Map.get(attrs, :cost_usd)),
      ok: Map.get(attrs, :ok, true) == true
    })
  end

  def record_llm(_, _), do: :ok

  @doc """
  One finished tool call. Keys: `:name`, `:id`, `:args` (the raw argument
  map - only a hash and a short hint are kept), `:hint`, `:duration_ms`,
  `:success`.
  """
  @spec record_tool(String.t(), map()) :: :ok
  def record_tool(session_id, attrs) when is_map(attrs) do
    name = attrs |> Map.get(:name) |> to_string() |> canonical_tool_name()
    args = Map.get(attrs, :args)
    args = if is_map(args), do: args, else: %{}

    put(session_id, :tool, %{
      id: Map.get(attrs, :id),
      name: name,
      args_hash: :erlang.phash2(args),
      hint: preview(default_hint(args) || Map.get(attrs, :hint), 60),
      duration_ms: int(Map.get(attrs, :duration_ms)),
      success: Map.get(attrs, :success, true) == true,
      read_only: read_only?(name, args)
    })
  end

  def record_tool(_, _), do: :ok

  @doc "Time a tool call spent parked on the user's approval."
  @spec record_approval_wait(String.t(), map()) :: :ok
  def record_approval_wait(session_id, attrs) when is_map(attrs) do
    put(session_id, :approval, %{
      tool: to_string(Map.get(attrs, :tool) || "?"),
      id: Map.get(attrs, :id),
      wait_ms: int(Map.get(attrs, :wait_ms)),
      outcome: attrs |> Map.get(:outcome) |> string_or_nil()
    })
  end

  def record_approval_wait(_, _), do: :ok

  @doc """
  A retry or recovery. `kind` names the mechanism (`:provider_retry`,
  `:provider_fallback`, `:tool_retry`, `:loop_recovery`, …); `detail` is a short
  human-readable reason.
  """
  @spec record_recovery(String.t(), atom() | String.t(), term()) :: :ok
  def record_recovery(session_id, kind, detail \\ nil) do
    put(session_id, :recovery, %{mechanism: to_string(kind), detail: preview(detail, 100)})
  end

  defp put(session_id, kind, data) when is_binary(session_id) do
    case :ets.lookup(@meta, session_id) do
      [{^session_id, %{turn: turn}}] ->
        :ets.insert(@events, {{session_id, turn}, now(), kind, data})

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp put(_, _, _), do: :ok

  # Models call tools by alias (`bash_execute` for `shell_execute`, ...). The
  # trace groups, classifies and compares by the canonical name.
  defp canonical_tool_name(""), do: "?"

  defp canonical_tool_name(name) do
    case OptimalSystemAgent.Tools.Registry.module_for_alias(name) do
      mod when is_atom(mod) and not is_nil(mod) -> to_string(mod.name())
      _ -> name
    end
  rescue
    _ -> name
  end

  # ── Reading ──────────────────────────────────────────────────────────

  @doc """
  Summary of the current turn of `session_id` (running or finished), or `nil`
  when the session has no recorded turn.
  """
  @spec latest(String.t()) :: summary() | nil
  def latest(session_id) when is_binary(session_id) do
    case :ets.lookup(@meta, session_id) do
      [{^session_id, meta}] ->
        summarize(Map.delete(meta, :history), events(session_id, meta.turn))

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def latest(_), do: nil

  @doc "Summaries of the retained turns of `session_id`, newest first."
  @spec turns(String.t()) :: [summary()]
  def turns(session_id) when is_binary(session_id) do
    case :ets.lookup(@meta, session_id) do
      [{^session_id, meta}] ->
        [Map.delete(meta, :history) | Map.get(meta, :history, [])]
        |> Enum.map(&summarize(&1, events(session_id, &1.turn)))

      _ ->
        []
    end
  rescue
    _ -> []
  end

  def turns(_), do: []

  @doc "Forget every recorded turn of `session_id`."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    case :ets.lookup(@meta, session_id) do
      [{^session_id, meta}] ->
        [meta | Map.get(meta, :history, [])]
        |> Enum.each(fn %{turn: n} -> :ets.delete(@events, {session_id, n}) end)

      _ ->
        :ok
    end

    :ets.delete(@meta, session_id)
    :ok
  rescue
    _ -> :ok
  end

  defp events(session_id, turn) do
    @events
    |> :ets.lookup({session_id, turn})
    |> Enum.map(fn {_key, at, kind, data} -> Map.merge(data, %{kind: kind, at: at}) end)
    |> Enum.sort_by(& &1.at)
  end

  # ── Summary (pure) ───────────────────────────────────────────────────

  @doc """
  Fold one turn's metadata and events into the summary `/trace` and the HTTP
  API show. Pure, so it is unit-testable with hand-built events.

  Event maps carry `:kind` (`:llm | :tool | :approval | :recovery`) and `:at`
  (monotonic ms when the event was recorded, i.e. when the step ENDED).
  """
  @spec summarize(map(), [map()]) :: summary()
  def summarize(meta, events) do
    end_mono = meta[:ended_mono] || now()
    wall_ms = max(end_mono - (meta[:started_mono] || end_mono), 0)

    llm = Enum.filter(events, &(&1.kind == :llm))
    tools = Enum.filter(events, &(&1.kind == :tool))
    approvals = Enum.filter(events, &(&1.kind == :approval))
    recoveries = Enum.filter(events, &(&1.kind == :recovery))

    {bg_tools, work_tools} = Enum.split_with(tools, &(&1.name in @background_wait_tools))

    model_ms = sum(llm, :duration_ms)
    approval_ms = sum(approvals, :wait_ms)
    background_ms = sum(bg_tools, :duration_ms)

    # Tools run concurrently, so their wall time is the UNION of their
    # intervals, not the sum. Approval waits sit inside a call's interval.
    tool_union_ms = union_ms(Enum.map(tools, &{&1.at - &1.duration_ms, &1.at}))
    tool_ms = max(tool_union_ms - approval_ms - background_ms, 0)

    # What neither the model nor a tool accounts for: context build, compaction,
    # hooks, the harness itself. Model and tool intervals can overlap (tools
    # started mid-stream), so this is floored at zero rather than trusted to be
    # an exact remainder.
    busy_ms =
      union_ms(
        Enum.map(llm, &{&1.at - &1.duration_ms, &1.at}) ++
          Enum.map(tools, &{&1.at - &1.duration_ms, &1.at})
      )

    other_ms = max(wall_ms - busy_ms, 0)

    wasted = wasted_steps(tools)

    %{
      turn: meta[:turn],
      status: to_string(meta[:status] || :running),
      started_at: meta[:started_at],
      model: meta[:model],
      provider: meta[:provider],
      prompt: meta[:prompt],
      wall_ms: wall_ms,
      breakdown: %{
        model_ms: model_ms,
        tool_ms: tool_ms,
        approval_ms: approval_ms,
        background_ms: background_ms,
        other_ms: other_ms
      },
      llm: %{
        calls: length(llm),
        failed: Enum.count(llm, &(not &1.ok)),
        ms: model_ms,
        input_tokens: sum(llm, :input_tokens),
        output_tokens: sum(llm, :output_tokens),
        cache_read_tokens: sum(llm, :cache_read_tokens),
        cost_usd: llm |> Enum.map(& &1.cost_usd) |> Enum.sum() |> Kernel.*(1.0) |> Float.round(6),
        slowest_ms: llm |> Enum.map(& &1.duration_ms) |> Enum.max(fn -> 0 end)
      },
      tools: %{
        calls: length(work_tools),
        failed: Enum.count(tools, &(not &1.success)),
        union_ms: tool_union_ms,
        per_tool: per_tool(tools),
        slowest:
          tools
          |> Enum.sort_by(& &1.duration_ms, :desc)
          |> Enum.take(5)
          |> Enum.map(&%{name: &1.name, hint: &1.hint, ms: &1.duration_ms, success: &1.success})
      },
      approval: %{
        waits: length(approvals),
        ms: approval_ms,
        items: Enum.map(approvals, &Map.take(&1, [:tool, :wait_ms, :outcome]))
      },
      background: %{calls: length(bg_tools), ms: background_ms},
      recoveries: %{
        count: length(recoveries),
        by_kind: Enum.frequencies_by(recoveries, & &1.mechanism),
        items: recoveries |> Enum.take(10) |> Enum.map(&Map.take(&1, [:mechanism, :detail]))
      },
      wasted: wasted
    }
  end

  defp per_tool(tools) do
    tools
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, calls} ->
      %{
        name: name,
        calls: length(calls),
        total_ms: sum(calls, :duration_ms),
        max_ms: calls |> Enum.map(& &1.duration_ms) |> Enum.max(fn -> 0 end),
        failed: Enum.count(calls, &(not &1.success))
      }
    end)
    |> Enum.sort_by(&{-&1.total_ms, &1.name})
  end

  # An identical successful read-only probe, repeated while nothing was written,
  # re-fetched a fact the model already had. Any non-read-only call resets the
  # window: re-reading after an edit (or after a command that may have changed
  # things) is verification, not waste.
  defp wasted_steps(tools) do
    {_seen, wasted} =
      Enum.reduce(tools, {MapSet.new(), []}, fn t, {seen, wasted} ->
        key = {t.name, t.args_hash}

        cond do
          not t.read_only -> {MapSet.new(), wasted}
          MapSet.member?(seen, key) -> {seen, [t | wasted]}
          t.success -> {MapSet.put(seen, key), wasted}
          true -> {seen, wasted}
        end
      end)

    wasted = Enum.reverse(wasted)

    %{
      count: length(wasted),
      ms: sum(wasted, :duration_ms),
      items:
        wasted
        |> Enum.frequencies_by(&{&1.name, &1.hint})
        |> Enum.map(fn {{name, hint}, n} -> %{name: name, hint: hint, repeats: n} end)
        |> Enum.sort_by(&(-&1.repeats))
    }
  end

  @doc false
  # Length of the union of `{start, stop}` intervals.
  @spec union_ms([{integer(), integer()}]) :: non_neg_integer()
  def union_ms(intervals) do
    intervals
    |> Enum.filter(fn {a, b} -> b > a end)
    |> Enum.sort()
    |> Enum.reduce({0, nil}, fn
      {a, b}, {total, nil} -> {total, {a, b}}
      {a, b}, {total, {ca, cb}} when a <= cb -> {total, {ca, max(cb, b)}}
      {a, b}, {total, {ca, cb}} -> {total + (cb - ca), {a, b}}
    end)
    |> case do
      {total, nil} -> total
      {total, {a, b}} -> total + (b - a)
    end
  end

  @doc """
  Is this call provably read-only? File/search tools by name; `shell_execute`
  only when `ShellExecute.ReadOnly` proves the whole command line writes
  nothing.
  """
  @spec read_only?(String.t(), map()) :: boolean()
  def read_only?("shell_execute", args),
    do: ReadOnly.provably_read_only?(Map.get(args, "command") || Map.get(args, :command))

  def read_only?(name, _args), do: name in @read_only_tools

  # ── Rendering ────────────────────────────────────────────────────────

  @doc """
  The compact table `/trace` prints. `nil` renders the "nothing recorded yet"
  line.
  """
  @spec format(summary() | nil) :: String.t()
  def format(nil), do: "No turn recorded for this session yet."

  def format(s) do
    b = s.breakdown
    wall = max(s.wall_ms, 1)

    header =
      "Turn #{s.turn} · #{s.status} · #{secs(s.wall_ms)} wall" <>
        if(s.model, do: " · #{s.model}", else: "")

    rows = [
      {"model", b.model_ms,
       "#{s.llm.calls} call#{plural(s.llm.calls)} · #{tokens(s.llm.input_tokens)} in / " <>
         "#{tokens(s.llm.output_tokens)} out" <>
         if(s.llm.cost_usd > 0,
           do: " · $#{:erlang.float_to_binary(s.llm.cost_usd, decimals: 4)}",
           else: ""
         ) <>
         if(s.llm.failed > 0, do: " · #{s.llm.failed} failed", else: "")},
      {"tools", b.tool_ms,
       "#{s.tools.calls} call#{plural(s.tools.calls)}" <> failed(s.tools.failed)},
      {"approval", b.approval_ms,
       if(s.approval.waits > 0,
         do: "#{s.approval.waits} wait#{plural(s.approval.waits)} on you",
         else: ""
       )},
      {"background", b.background_ms,
       if(s.background.calls > 0,
         do: "#{s.background.calls} wait#{plural(s.background.calls)}",
         else: ""
       )},
      {"other", b.other_ms, "context, hooks, harness"}
    ]

    table =
      [pad("where", 11) <> lpad("time", 8) <> lpad("share", 7) <> "  detail"] ++
        Enum.map(rows, fn {label, ms, detail} ->
          pad(label, 11) <>
            lpad(secs(ms), 8) <> lpad("#{round(ms * 100 / wall)}%", 7) <> "  " <> detail
        end)

    per_tool =
      case s.tools.per_tool do
        [] ->
          []

        list ->
          [
            "",
            pad("tool", 18) <>
              lpad("calls", 6) <> lpad("total", 8) <> lpad("max", 8) <> lpad("fail", 6)
          ] ++
            Enum.map(Enum.take(list, 8), fn t ->
              pad(t.name, 18) <>
                lpad(to_string(t.calls), 6) <>
                lpad(secs(t.total_ms), 8) <>
                lpad(secs(t.max_ms), 8) <>
                lpad(if(t.failed > 0, do: to_string(t.failed), else: ""), 6)
            end)
      end

    slowest =
      case Enum.filter(s.tools.slowest, &(&1.ms > 0)) |> Enum.take(3) do
        [] ->
          []

        list ->
          ["", "slowest calls"] ++
            Enum.map(list, fn c ->
              "  " <>
                lpad(secs(c.ms), 7) <>
                "  " <> c.name <> if(c.hint in [nil, ""], do: "", else: "  " <> c.hint)
            end)
      end

    retries =
      if s.recoveries.count > 0 do
        kinds =
          s.recoveries.by_kind
          |> Enum.map_join(", ", fn {k, n} -> "#{k} ×#{n}" end)

        ["", "retries/recoveries: #{s.recoveries.count} (#{kinds})"]
      else
        ["", "retries/recoveries: none"]
      end

    wasted =
      if s.wasted.count > 0 do
        examples =
          s.wasted.items
          |> Enum.take(3)
          |> Enum.map_join("; ", fn w ->
            "#{w.name}#{if w.hint in [nil, ""], do: "", else: " " <> w.hint} ×#{w.repeats}"
          end)

        [
          "wasted: #{s.wasted.count} repeated read-only probe#{plural(s.wasted.count)} " <>
            "(#{secs(s.wasted.ms)}) - #{examples}"
        ]
      else
        ["wasted: none"]
      end

    Enum.join([header, ""] ++ table ++ per_tool ++ slowest ++ retries ++ wasted, "\n")
  end

  defp failed(0), do: ""
  defp failed(n), do: " · #{n} failed"

  defp plural(1), do: ""
  defp plural(_), do: "s"

  @doc false
  def secs(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  def secs(ms) when is_integer(ms) and ms < 60_000,
    do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)}s"

  def secs(ms) when is_integer(ms) do
    m = div(ms, 60_000)
    s = div(rem(ms, 60_000), 1000)
    "#{m}m#{String.pad_leading(to_string(s), 2, "0")}s"
  end

  def secs(_), do: "0ms"

  defp tokens(n) when n >= 1000, do: "#{:erlang.float_to_binary(n / 1000, decimals: 1)}k"
  defp tokens(n), do: to_string(n)

  defp pad(s, n), do: String.pad_trailing(s, n)
  defp lpad(s, n), do: String.pad_leading(s, n)

  # ── Helpers ──────────────────────────────────────────────────────────

  defp now, do: System.monotonic_time(:millisecond)

  defp sum(list, key), do: Enum.reduce(list, 0, &(int(Map.get(&1, key)) + &2))

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(n) when is_float(n) and n >= 0, do: round(n)
  defp int(_), do: 0

  defp num(n) when is_number(n), do: n * 1.0
  defp num(_), do: 0.0

  defp string_or_nil(nil), do: nil
  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(a) when is_atom(a), do: Atom.to_string(a)
  defp string_or_nil(other), do: inspect(other)

  defp default_hint(args) do
    Map.get(args, "path") || Map.get(args, "command") || Map.get(args, "pattern") ||
      Map.get(args, :path) || Map.get(args, :command)
  end

  defp preview(nil, _), do: nil

  defp preview(text, max) do
    text = if is_binary(text), do: text, else: inspect(text)

    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max)
  end
end
