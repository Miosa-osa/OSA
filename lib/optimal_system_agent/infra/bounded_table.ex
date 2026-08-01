defmodule OptimalSystemAgent.Infra.BoundedTable do
  @moduledoc """
  A row-count cap for append-mostly named ETS tables.

  Several subsystems keep a public named ETS table that is only ever inserted
  into — `:osa_healing_sessions`, `:osa_speculative_executions`,
  `:osa_peer_negotiations`, `:osa_peer_handoffs`, `:osa_peer_queries`,
  `:osa_peer_reviews`, `:osa_reminders_claimed`. Their rows are *history*: a
  finished healing session, a resolved handoff, a peer query that already got
  its answer. Nothing read them again and nothing deleted them, so the peer
  tables in particular accrued one permanent row per tool call and grew for the
  life of the daemon.

  `insert/4` writes through to the real table and evicts the oldest rows once it
  exceeds `:max`. Eviction is by insertion recency, which for history rows is
  the right policy: the newest records are the ones a caller might still look
  up, and the oldest are finished work nobody will ask about again.

  ## Bookkeeping without dynamic atoms

  Ordering is kept in TWO shared, fixed tables rather than a companion table per
  bounded table — deriving a companion name like `:"\#{table}_order"` would mint
  an atom per table, the very failure mode `Teams.TableRegistry` had to be
  rewritten to avoid:

    * `:osa_bounded_order` — `:ordered_set` of `{{table, seq}, key}`
    * `:osa_bounded_seq`   — `:set` of `{{table, key}, seq}`

  Both are keyed by the table name, so any number of bounded tables share them
  and no new atoms are ever created.

  Re-inserting an existing key refreshes its position instead of adding a second
  ordering entry, so update-in-place call sites (very common in these modules —
  a status transition rewrites the same row) do not inflate the bookkeeping.

  Every function is best-effort and never raises: a bound is a safety net, and a
  failure to prune must never break the caller that was writing real state.
  """

  require Logger

  @order_table :osa_bounded_order
  @seq_table :osa_bounded_seq

  @default_max 1_000

  @doc """
  Insert `{key, value}` into `table`, then evict oldest rows past the cap.

  Options:
    * `:max` — row cap (default `#{@default_max}`). `0` disables eviction.

  Returns `:ok`.
  """
  @spec insert(atom(), term(), term(), keyword()) :: :ok
  def insert(table, key, value, opts \\ []) do
    :ets.insert(table, {key, value})
    note(table, key)
    enforce(table, Keyword.get(opts, :max, @default_max))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Delete `key` from `table` and drop its ordering bookkeeping."
  @spec delete(atom(), term()) :: :ok
  def delete(table, key) do
    :ets.delete(table, key)
    forget(table, key)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  `:ets.insert_new/2` with the same cap. Returns the boolean `insert_new` gave,
  so claim-style callers (`Agent.Reminders`) keep their exactly-once semantics.
  """
  @spec insert_new(atom(), term(), term(), keyword()) :: boolean()
  def insert_new(table, key, value, opts \\ []) do
    case :ets.insert_new(table, {key, value}) do
      true ->
        note(table, key)
        enforce(table, Keyword.get(opts, :max, @default_max))
        true

      false ->
        false
    end
  rescue
    _ -> false
  end

  @doc "Current row count of `table` (0 when it does not exist)."
  @spec size(atom()) :: non_neg_integer()
  def size(table) do
    case :ets.info(table, :size) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc "Default cap, for callers that want to document theirs relative to it."
  @spec default_max() :: pos_integer()
  def default_max, do: @default_max

  @doc """
  Create the shared ordering tables up front, from a long-lived process.

  Called from `Application.start/2` (Phase 2) for the same reason
  `Agent.RunStore.init_store/0` is: a named ETS table is owned by whichever
  process created it and dies with that process. Left to lazy creation, the
  first `insert/4` in the VM — very often a short-lived Task or a per-request
  GenServer — became the owner of the ordering tables for EVERY bounded table
  in the system, and when it exited the tables vanished.

  That is silent and it is not benign: `ensure_tables/0` recreates them EMPTY,
  so rows already in a bounded table have no ordering entry, `oldest/1` cannot
  see them, and eviction then falls on the newest rows instead of the oldest —
  the exact inversion `bounded_table_test.exs`'s "eviction is oldest-first"
  case caught intermittently. Owning them here removes the race entirely; the
  lazy path stays as a fallback for callers running without the application
  started (unit tests, scripts).
  """
  @spec init_tables() :: :ok
  def init_tables, do: ensure_tables()

  # ── Private ──────────────────────────────────────────────────────────

  defp ensure_tables do
    new_table(@order_table, :ordered_set)
    new_table(@seq_table, :set)
    :ok
  end

  defp new_table(name, type) do
    :ets.new(name, [:named_table, type, :public])
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp note(table, key) do
    ensure_tables()
    forget(table, key)

    seq = System.unique_integer([:monotonic, :positive])
    :ets.insert(@order_table, {{table, seq}, key})
    :ets.insert(@seq_table, {{table, key}, seq})
    :ok
  rescue
    _ -> :ok
  end

  defp forget(table, key) do
    ensure_tables()

    case :ets.lookup(@seq_table, {table, key}) do
      [{_, seq}] -> :ets.delete(@order_table, {table, seq})
      _ -> :ok
    end

    :ets.delete(@seq_table, {table, key})
    :ok
  rescue
    _ -> :ok
  end

  defp enforce(_table, max) when not is_integer(max) or max <= 0, do: :ok

  defp enforce(table, max) do
    if size(table) > max do
      case oldest(table) do
        nil ->
          # Bookkeeping is gone but the table is over cap (someone inserted
          # around us). Nothing safe and cheap to evict — leave it; the next
          # insert that goes through here re-establishes ordering.
          :ok

        {order_key, key} ->
          # Concurrent callers race on `note/2` + `forget/2` (both are
          # multi-step read-then-write over two ETS tables, no lock), so the
          # `{order_key, key}` pointer `oldest/1` just read can already be
          # stale by the time we get here: another process may have already
          # refreshed `key`'s recency (new seq) or deleted it outright. Acting
          # on a stale pointer via `forget/2` is a no-op — it only ever
          # removes whatever @seq_table *currently* points at, never the
          # specific stale `order_key` we hold — so the same dead entry would
          # be handed back by every subsequent `oldest/1` call and `enforce/2`
          # would recurse forever without shrinking anything (this was a real
          # deadlock under concurrent insert/enforce). Verify the pointer is
          # still current before treating it as a real row to evict; if it
          # isn't, drop the stale order entry directly — either branch always
          # removes at least one entry, so the recursion provably terminates.
          case :ets.lookup(@seq_table, {table, key}) do
            [{_, seq}] when {table, seq} == order_key ->
              :ets.delete(table, key)
              forget(table, key)

            _ ->
              :ets.delete(@order_table, order_key)
          end

          enforce(table, max)
      end
    else
      :ok
    end
  end

  # Smallest seq recorded for `table`. Keys are `{table, seq}` in an ordered_set,
  # so the successor of `{table, 0}` is this table's oldest entry — provided it
  # still belongs to this table. Returns `{order_key, key}` so the caller can
  # tell a stale/orphaned pointer from a live one instead of trusting `key`
  # alone.
  defp oldest(table) do
    case :ets.next(@order_table, {table, 0}) do
      {^table, _seq} = order_key ->
        case :ets.lookup(@order_table, order_key) do
          [{^order_key, key}] -> {order_key, key}
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
