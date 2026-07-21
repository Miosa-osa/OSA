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

  # Upper bound on run rows scanned when rolling up tree spend. Matches the
  # fleet-total kill switch (`Fleet.@default_max_fleet_total`) so a full fan_out
  # tree is always covered; keeps the read bounded on a huge/long-lived store.
  @tree_scan_limit 2_000

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
      |> maybe_put_last_input(norm.input_tokens)

    emit_cost_update(state, norm, turn_cost)
    maybe_bridge_budget(state, norm)

    state
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
    runs = RunStore.list(limit: @tree_scan_limit)

    children_by_parent =
      Enum.group_by(runs, fn run -> Map.get(run, :parent_session_id) end, fn run ->
        Map.get(run, :agent_id)
      end)

    root
    |> collect_descendants(children_by_parent, MapSet.new())
    |> Enum.reduce(0.0, fn agent_id, acc -> acc + node_cost_usd(agent_id) end)
  rescue
    _ -> 0.0
  end

  # Breadth-first walk of the run tree collecting every descendant agent_id.
  # `seen` guards against cycles / a node re-parented to an ancestor.
  defp collect_descendants(node, children_by_parent, seen) do
    children = Map.get(children_by_parent, node, [])

    Enum.reduce(children, [], fn child, acc ->
      if MapSet.member?(seen, child) do
        acc
      else
        seen = MapSet.put(seen, child)
        [child | collect_descendants(child, children_by_parent, seen)] ++ acc
      end
    end)
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
        norm.input_tokens + norm.cache_creation_input_tokens + norm.cache_read_input_tokens,
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

  defp maybe_put_last_input(state, input) when input > 0, do: put(state, :last_input_tokens, input)
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
end
