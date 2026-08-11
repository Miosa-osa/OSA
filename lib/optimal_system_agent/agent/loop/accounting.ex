defmodule OptimalSystemAgent.Agent.Loop.Accounting do
  @moduledoc """
  Per-session token and cost accounting for the agent loop (primitive #29).

  Accounting is **always on** — every LLM round-trip's usage object is parsed,
  priced via `OptimalSystemAgent.Agent.Pricing`, and accumulated into the loop
  state. The running spend is exposed on the state (`session_cost_usd` +
  per-kind token counters) so:

    * `Loop.Limits` can enforce a *real* `max_budget_usd` cap, and
    * the TUI / auto-mode can display live spend.

  This module is intentionally pure with respect to loop state — `record/2`
  takes a state and returns an updated state. Side effects are limited to
  emitting a `:cost_update` system event and a best-effort bridge to the global
  `OptimalSystemAgent.Budget` daily/monthly ledger.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Events.Bus

  @usage_keys [
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens
  ]

  @doc """
  Normalize a provider usage map into the canonical shape with all four token
  kinds present as non-negative integers.

  Accepts atom- or string-keyed maps (providers vary) and tolerates `nil`.
  """
  @spec normalize_usage(map() | nil) :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer()
        }
  def normalize_usage(nil), do: zero_usage()

  def normalize_usage(usage) when is_map(usage) do
    Map.new(@usage_keys, fn key -> {key, fetch_tok(usage, key)} end)
  end

  def normalize_usage(_), do: zero_usage()

  @doc """
  Total prompt tokens that actually occupied the model's context window for one
  round-trip: fresh input + cache writes + cache reads.

  Providers disagree about how they slice the prompt:

    * **Anthropic** (`Providers.Anthropic.extract_usage/1`) reports the three
      slices SEPARATELY — `input_tokens` counts only the uncached tail, with
      `cache_creation_input_tokens` and `cache_read_input_tokens` alongside it.
    * **OpenAI-compatible** (`Providers.OpenAICompat.parse_usage/1`) folds the
      whole prompt into `prompt_tokens` → `input_tokens`, leaving both cache
      fields at zero.

  So `input_tokens` alone is NOT comparable across providers: on Anthropic with
  caching active it is a small fraction of the real context occupancy, and it
  shrinks further the better caching works. Summing all three yields the same
  effective total in both shapes, which is the number every context-pressure
  consumer (`Loop.ProactiveCompaction.estimated_tokens/1`) actually wants.
  """
  @spec effective_input_tokens(map() | nil) :: non_neg_integer()
  def effective_input_tokens(usage) do
    norm = normalize_usage(usage)
    norm.input_tokens + norm.cache_creation_input_tokens + norm.cache_read_input_tokens
  end

  @doc """
  Record one LLM round-trip's usage into the session accounting on `state`.

  Parses `usage`, prices it against `state.model`, and accumulates cost and
  per-kind token counts. Returns the updated state. Also refreshes
  `last_input_tokens` (used by context-pressure telemetry) and emits a
  `:cost_update` event with the new running totals.
  """
  @spec record(map(), map() | nil) :: map()
  def record(state, usage) do
    do_record(state, usage)
  rescue
    e ->
      # Accounting is best-effort telemetry — a pricing/emit failure must never
      # crash the turn. Degrade to the un-updated state (this round-trip's spend
      # is simply not accumulated) rather than propagating the error into the
      # ReAct loop.
      Logger.warning("[Accounting] record failed, skipping this round-trip: #{inspect(e)}")
      state
  catch
    kind, reason ->
      Logger.warning("[Accounting] record caught #{kind}: #{inspect(reason)} — skipping")
      state
  end

  defp do_record(state, usage) do
    norm = normalize_usage(usage)
    turn_cost = Pricing.cost(Map.get(state, :model), norm)

    session_cost = round6(get(state, :session_cost_usd, 0.0) + turn_cost)

    input = get(state, :session_input_tokens, 0) + norm.input_tokens
    output = get(state, :session_output_tokens, 0) + norm.output_tokens
    cache_write = get(state, :session_cache_creation_tokens, 0) + norm.cache_creation_input_tokens
    cache_read = get(state, :session_cache_read_tokens, 0) + norm.cache_read_input_tokens

    state =
      state
      |> put(:session_cost_usd, session_cost)
      |> put(:session_input_tokens, input)
      |> put(:session_output_tokens, output)
      |> put(:session_cache_creation_tokens, cache_write)
      |> put(:session_cache_read_tokens, cache_read)
      |> maybe_put_last_input(effective_input_tokens(norm))

    # Surrender this round-trip's numbers OUTSIDE the immutable state thread,
    # so a turn that crashes after burning tokens can still be billed for them.
    # See `adopt_partial/1`.
    stash_partial(state)

    emit_cost_update(state, norm, turn_cost)
    maybe_bridge_budget(state, norm)
    maybe_record_trajectory(state, norm, turn_cost)

    state
  end

  # ── Partial-spend surrender across a crashed turn ────────────────────────
  #
  # `Loop.run_and_reply/1` wraps `ReactLoop.run/1` in a `try`. Both the `rescue`
  # and the `catch` arm return the state bound BEFORE the call, because on an
  # exception every intermediate state is unreachable — Elixir state is
  # immutable and threaded through the recursion, so the unwind takes it with
  # it. The consequence was that a turn which completed three billed round-trips
  # and then crashed on the fourth recorded a token delta of zero and dropped
  # that spend from session accounting entirely: the `:cost_update` stream, the
  # transcript's token column, and — worse — the `max_budget_usd` cap all went
  # on believing the money had never been spent.
  #
  # The seam is the process dictionary, which is the mechanism this codebase
  # already uses to carry work across an error boundary (`ReactLoop` drains
  # streamed tool results through `:osa_streaming_tool_ctx` the same way).
  # `ReactLoop.run/1` runs INLINE in the `Loop` GenServer process, so the key
  # written here survives the unwind and is readable by the rescue arm.
  #
  # ABSOLUTE counters are stashed, not deltas. Re-merging an absolute snapshot
  # is idempotent, so a duplicated or out-of-order merge cannot double-bill;
  # merging deltas twice would.
  @partial_key :osa_turn_accounting

  # Exactly the keys `do_record/2` writes. A counter added to accounting and
  # not to this list would be silently dropped on a crashed turn, which is the
  # bug this whole mechanism exists to fix — so the two lists must stay
  # together, and `accounting_test.exs` pins that they do.
  @partial_keys [
    :session_cost_usd,
    :session_input_tokens,
    :session_output_tokens,
    :session_cache_creation_tokens,
    :session_cache_read_tokens,
    :last_input_tokens
  ]

  defp stash_partial(state) do
    Process.put(@partial_key, Map.take(state, @partial_keys))
    :ok
  end

  @doc """
  Drop any stashed partial accounting.

  Called by `Loop.run_and_reply/1` at the TOP of every turn. The `Loop`
  GenServer is long-lived and the process dictionary is not, so without this a
  turn that crashed before its first round-trip would adopt the PREVIOUS turn's
  snapshot and bill it a second time.
  """
  @spec forget_partial() :: :ok
  def forget_partial do
    Process.delete(@partial_key)
    :ok
  end

  @doc """
  Merge any accounting recorded during a crashed turn back onto the pre-turn
  state.

  Deliberately merges ONLY the accounting keys. `state.messages`,
  `state.iteration` and `state.total_tool_calls` from a half-crashed turn are
  not recovered here and should not be: a message list interrupted mid-cycle can
  be structurally invalid (an assistant tool-call block with no matching tool
  result), and merging it would poison the next request to the provider.
  Recovering history is a separate, larger problem. Recovering the money is not.

  A no-op when nothing was recorded, so it is safe on every path.
  """
  @spec adopt_partial(map()) :: map()
  def adopt_partial(state) do
    case Process.get(@partial_key) do
      snapshot when is_map(snapshot) and map_size(snapshot) > 0 ->
        Map.merge(state, snapshot)

      _ ->
        state
    end
  end

  @doc """
  Return a compact spend snapshot for a session state — used by `Loop.get_state`
  so the TUI / auto-mode can display live spend.
  """
  @spec snapshot(map()) :: map()
  def snapshot(state) do
    %{
      cost_usd: round6(get(state, :session_cost_usd, 0.0)),
      input_tokens: get(state, :session_input_tokens, 0),
      output_tokens: get(state, :session_output_tokens, 0),
      cache_creation_tokens: get(state, :session_cache_creation_tokens, 0),
      cache_read_tokens: get(state, :session_cache_read_tokens, 0),
      max_budget_usd: get(state, :max_budget_usd, nil)
    }
  end

  # ══════════════════════════════════════════════════════════════════════
  # Fleet / tree budget rollup (W2)
  #
  # A `max_budget_usd` cap set on a parent must bound the WHOLE run tree — the
  # parent plus every descendant fleet node — not each node independently.
  # Otherwise N children each under their own (usually absent) cap can blow the
  # intended total (cap-defeat via fan-out).
  #
  # The rollup is READ-ONLY: it walks the run tree via `RunStore`
  # (`parent_session_id` links) and reads each descendant's persisted spend from
  # the durable `SessionPersistence` sidecar — the same sidecar `Checkpoint`
  # mirrors every tool cycle. Neither store is mutated here. Every read is
  # wrapped best-effort: a rollup failure degrades to the parent's own spend
  # rather than crashing the loop or wrongly reporting exhaustion.
  # ══════════════════════════════════════════════════════════════════════

  @doc """
  Total USD spend across the WHOLE run tree rooted at `state`'s session — the
  parent's own live `session_cost_usd` PLUS every descendant fleet node's
  persisted spend.

  This is what makes `max_budget_usd` bound the tree rather than each node. The
  parent's own spend is taken from the passed state (its live accumulator);
  descendant spend is summed read-only from `RunStore` + `SessionPersistence`,
  so a child's cost is never double-counted against the parent.
  """
  @spec tree_spend_usd(map()) :: float()
  def tree_spend_usd(state) when is_map(state) do
    own = own_cost(state)
    round6(own + descendants_spend_usd(Map.get(state, :session_id)))
  rescue
    e ->
      Logger.debug("[Accounting] tree_spend_usd rollup failed: #{inspect(e)}")
      own_cost(state)
  end

  @doc """
  True when the session has a real (`> 0`) `max_budget_usd` cap and the rolled-up
  WHOLE-TREE spend has reached it.

  This is the helper fan_out (and any budget guard) checks BEFORE spawning a new
  node — when it returns true, spawning must STOP and the exhaustion be surfaced
  rather than silently overspending. An absent / non-positive cap is never
  exhausted (uncapped).
  """
  @spec budget_exhausted?(map()) :: boolean()
  def budget_exhausted?(state) when is_map(state) do
    max = Map.get(state, :max_budget_usd)
    is_number(max) and max > 0 and tree_spend_usd(state) >= max
  end

  @doc """
  Remaining tree budget in USD (`max_budget_usd` minus rolled-up tree spend,
  floored at 0.0), or `:infinity` when there is no positive cap.
  """
  @spec tree_budget_remaining(map()) :: float() | :infinity
  def tree_budget_remaining(state) when is_map(state) do
    max = Map.get(state, :max_budget_usd)

    if is_number(max) and max > 0 do
      max(0.0, round6(max - tree_spend_usd(state)))
    else
      :infinity
    end
  end

  # Sum the persisted spend of every descendant of `root` in the run tree.
  defp descendants_spend_usd(nil), do: 0.0

  defp descendants_spend_usd(root) do
    root
    |> collect_descendants()
    |> Enum.reduce(0.0, fn agent_id, acc -> acc + node_cost_usd(agent_id) end)
  rescue
    _ -> 0.0
  end

  @doc false
  # Every descendant agent_id of `root`, walked over `RunStore.children_of/1`.
  #
  # This deliberately does NOT go through `RunStore.list/1`: that list is capped
  # AND machine-wide AND fed by a table `prune_terminal/0`
  # evicts from, so a wide fan-out would drop its own finished nodes out of the
  # rollup, unrelated sessions could evict tree members, and an exhausted budget
  # would flip back to "not exhausted" mid-spawn. The edge ledger is unpruned.
  def collect_descendants(root) do
    bfs([root], MapSet.new([root]), [])
  end

  # Iterative BFS with a SINGLE `seen` set threaded across the whole frontier.
  # The previous recursive form rebound `seen` inside the reduce closure, so the
  # guard was per-path: two sibling branches converging on the same node counted
  # that node's cost twice.
  defp bfs([], _seen, acc), do: Enum.reverse(acc)

  defp bfs([node | rest], seen, acc) do
    {next, seen} =
      node
      |> RunStore.children_of()
      |> Enum.reduce({[], seen}, fn child, {queued, seen} ->
        if MapSet.member?(seen, child) do
          {queued, seen}
        else
          {[child | queued], MapSet.put(seen, child)}
        end
      end)

    next = Enum.reverse(next)
    bfs(rest ++ next, seen, Enum.reverse(next, acc))
  end

  # A single node's real spend, from its durable sidecar (never raises).
  defp node_cost_usd(agent_id) when is_binary(agent_id) do
    case SessionPersistence.load_spend(agent_id) do
      %{cost_usd: c} when is_number(c) and c >= 0 -> c * 1.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  end

  defp node_cost_usd(_), do: 0.0

  defp own_cost(state) do
    case Map.get(state, :session_cost_usd, 0.0) do
      n when is_number(n) -> n * 1.0
      _ -> 0.0
    end
  end

  # --- Private ---

  defp emit_cost_update(state, norm, turn_cost) do
    payload = %{
      event: :cost_update,
      session_id: Map.get(state, :session_id),
      model: Map.get(state, :model),
      turn_cost_usd: turn_cost,
      session_cost_usd: get(state, :session_cost_usd, 0.0),
      max_budget_usd: get(state, :max_budget_usd, nil),
      usage: norm
    }

    Bus.emit(:system_event, payload)

    if sid = Map.get(state, :session_id) do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{sid}",
        {:osa_event, Map.put(payload, :type, :cost_update)}
      )
    end

    :ok
  rescue
    e ->
      Logger.debug("[Accounting] emit_cost_update failed: #{inspect(e)}")
      :ok
  end

  # Bridge real usage into the global daily/monthly ledger when it is running.
  # Fire-and-forget; never let ledger bookkeeping crash the loop.
  defp maybe_bridge_budget(state, norm) do
    if Process.whereis(OptimalSystemAgent.Budget) do
      OptimalSystemAgent.Budget.record_cost(
        provider_atom(Map.get(state, :provider)),
        to_string(Map.get(state, :model)),
        effective_input_tokens(norm),
        norm.output_tokens,
        Map.get(state, :session_id)
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp provider_atom(p) when is_atom(p) and not is_nil(p), do: p

  defp provider_atom(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> :default
  end

  defp provider_atom(_), do: :default

  defp maybe_put_last_input(state, input) when input > 0,
    do: put(state, :last_input_tokens, input)

  defp maybe_put_last_input(state, _), do: state

  defp fetch_tok(usage, key) do
    val = Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) || 0
    if is_integer(val) and val >= 0, do: val, else: 0
  end

  defp zero_usage,
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }

  defp get(state, key, default) do
    case Map.get(state, key, default) do
      nil -> default
      val -> val
    end
  end

  defp put(state, key, value), do: Map.put(state, key, value)

  defp round6(n) when is_float(n), do: Float.round(n, 6)
  defp round6(n), do: n

  defp maybe_record_trajectory(state, norm, turn_cost) do
    try do
      messages = Map.get(state, :messages, [])
      {last_assistant, tool_calls, tool_results} = extract_last_turn(messages)

      OptimalSystemAgent.Agent.Trajectory.record(%{
        session_id: Map.get(state, :session_id, ""),
        model: Map.get(state, :model, ""),
        input_tokens: norm.input_tokens,
        output_tokens: norm.output_tokens,
        cache_creation_tokens: Map.get(norm, :cache_creation_input_tokens, 0),
        cache_read_tokens: Map.get(norm, :cache_read_input_tokens, 0),
        cost_usd: turn_cost,
        tool_calls: tool_calls,
        tool_results: tool_results,
        assistant_response: last_assistant,
        context_utilization: extract_utilization(state, messages),
        compaction_events: []
      })
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp extract_last_turn(messages) when is_list(messages) do
    # Walk backwards: find the last assistant message and any tool results after it
    reversed = Enum.reverse(messages)

    {assistant, tool_results} =
      Enum.reduce_while(reversed, {nil, []}, fn msg, {acc_asst, acc_tools} ->
        role = Map.get(msg, :role)

        cond do
          role == "assistant" and acc_asst == nil ->
            content = Map.get(msg, :content, "")
            {:halt, {content, acc_tools}}

          role == "tool" ->
            {:cont, {acc_asst, [Map.get(msg, :content, "") | acc_tools]}}

          true ->
            {:cont, {acc_asst, acc_tools}}
        end
      end)

    {assistant || "", extract_tool_calls_from_messages(reversed), tool_results}
  end

  defp extract_last_turn(_), do: {"", [], []}

  defp extract_tool_calls(nil), do: []

  defp extract_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn tc ->
      %{name: Map.get(tc, :name, ""), arguments: Map.get(tc, :arguments, %{})}
    end)
  end

  defp extract_tool_calls(_), do: []

  # Extract tool calls from the last assistant message in the (reversed) list
  defp extract_tool_calls_from_messages([]), do: []

  defp extract_tool_calls_from_messages([msg | rest]) do
    case Map.get(msg, :role) do
      "assistant" ->
        extract_tool_calls(Map.get(msg, :tool_calls, []))

      _ ->
        extract_tool_calls_from_messages(rest)
    end
  end

  defp extract_utilization(state, _messages) do
    last_input = Map.get(state, :last_input_tokens, 0)

    if last_input > 0 do
      max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
      Float.round(last_input / max_tokens * 100, 1)
    else
      0.0
    end
  end
end
