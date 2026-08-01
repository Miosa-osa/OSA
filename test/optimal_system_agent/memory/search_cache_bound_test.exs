defmodule OptimalSystemAgent.Memory.SearchCacheBoundTest do
  @moduledoc """
  Bounds tests for the `:osa_memory_vectors` ETS cache.

  This table held one embedding vector — a full float list, the heaviest
  per-row growth in the codebase — per memory entry, with no cap, no TTL and no
  prune. The only removal was `forget/1` on explicit entry deletion.

  `Memory.Consolidator` looks like it covers this and does not, so there is a
  test below pinning that fact: if someone later wires consolidation to the
  vector cache, this test should be the thing that makes them update the
  comments rather than leave a prune that appears to cover something it doesn't.

  `async: false` — the cache is a shared, process-independent named ETS table.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Memory.Search

  @vector_table :osa_memory_vectors

  # Fill the cache through the real `embed_cached/2` write-through path, so LRU
  # bookkeeping and cap enforcement run exactly as in production — but with the
  # provider call stubbed out via `:embedding_fun` instead of hitting Ollama.
  #
  # This used to call `embed_cached/2` for its side effects and then
  # `:ets.insert/2` the wanted vector directly. That made the bound assertions
  # depend on a live embedding provider: when the embed failed (Ollama down,
  # busy, or slow enough to time out under a full-suite run) `embed_cached/2`
  # returned `{:error, _}` and never reached `safe_insert/3`, so the raw insert
  # landed in `:osa_memory_vectors` with NO recency entry and NO cap
  # enforcement — and the cap assertions below failed with the full 500 rows.
  # The bound was fine; the seeding was not. Stubbing the provider makes these
  # tests measure the LRU code and nothing else.
  defp seed(id, content, vector) do
    stub_embedder(vector)
    {:ok, ^vector} = Search.embed_cached(id, content)
    :ok
  end

  defp stub_embedder(vector) do
    Application.put_env(:optimal_system_agent, :embedding_fun, fn _text -> {:ok, vector} end)
  end

  # Remove ONLY the durable row for `id`, leaving the ETS cache alone
  # (`Search.forget/1` drops both). Best-effort: persistence is optional in
  # `Memory.Search`, so a missing row or an unavailable Repo is not a failure.
  defp drop_persisted(id) do
    case OptimalSystemAgent.Store.Repo.get(OptimalSystemAgent.Memory.VectorEntry, id) do
      nil -> :ok
      row -> OptimalSystemAgent.Store.Repo.delete(row)
    end

    :ok
  rescue
    _ -> :ok
  end

  setup do
    prev = Application.get_env(:optimal_system_agent, :memory_vector_cache_max)
    prev_embed = Application.get_env(:optimal_system_agent, :embedding_fun)
    Search.clear_cache()

    on_exit(fn ->
      if prev == nil do
        Application.delete_env(:optimal_system_agent, :memory_vector_cache_max)
      else
        Application.put_env(:optimal_system_agent, :memory_vector_cache_max, prev)
      end

      if prev_embed == nil do
        Application.delete_env(:optimal_system_agent, :embedding_fun)
      else
        Application.put_env(:optimal_system_agent, :embedding_fun, prev_embed)
      end

      Search.clear_cache()
    end)

    :ok
  end

  defp with_cap(n, fun) do
    Application.put_env(:optimal_system_agent, :memory_vector_cache_max, n)
    fun.()
  end

  describe "the bound" do
    # These tests drive `embed_cached/2` hundreds of times against a stubbed
    # embedder (see `seed/3`), so they exercise only the LRU/cap code and take
    # the same time on a busy box as on an idle one. No network, no timeout tag.
    test "driving 500 distinct entries past a cap of 25 keeps the table at the cap" do
      with_cap(25, fn ->
        Enum.each(1..500, fn i ->
          seed("bound-#{i}", "content #{i}", [i * 1.0, 2.0, 3.0])
        end)

        assert Search.cache_size() <= 25,
               "vector cache must stay at its cap, got #{Search.cache_size()}"
      end)
    end

    test "the cap holds no matter how many times it is exceeded" do
      with_cap(10, fn ->
        Enum.each(1..5, fn round ->
          Enum.each(1..100, fn i ->
            seed("round-#{round}-#{i}", "c#{round}#{i}", [1.0, 2.0, 3.0])
          end)

          assert Search.cache_size() <= 10
        end)
      end)
    end

    test "eviction is least-recently-used, so a hot vector survives a flood" do
      with_cap(5, fn ->
        seed("hot", "the hot entry", [9.0, 9.0, 9.0])

        # `embed_cached/2` falls back to the durable `memory_vectors` row on an
        # ETS miss, which would silently re-warm "hot" after an eviction and
        # let a plain FIFO cache pass this test. Drop the persisted copy so the
        # only place [9.0, 9.0, 9.0] can come from is the ETS cache: once
        # evicted, the read below falls through to the stub embedder, which by
        # then returns the cold vector, and the assertion fails as it should.
        drop_persisted("hot")

        Enum.each(1..40, fn i ->
          # Re-reading "hot" refreshes its recency; a pure insertion-order
          # (FIFO) cache would have dropped it long before entry 40.
          assert {:ok, [9.0, 9.0, 9.0]} = Search.embed_cached("hot", "the hot entry")
          seed("cold-#{i}", "cold #{i}", [1.0, 1.0, 1.0])
        end)

        assert Search.cache_size() <= 5
        assert :ets.lookup(@vector_table, "hot") != [], "the hot entry must not be evicted"
        assert :ets.lookup(@vector_table, "cold-1") == []
      end)
    end

    test "the LRU bookkeeping tables stay bounded too" do
      with_cap(10, fn ->
        Enum.each(1..300, fn i -> seed("bk-#{i}", "c#{i}", [1.0]) end)

        # Bookkeeping must not become the leak it was meant to fix.
        assert :ets.info(:osa_memory_vectors_lru, :size) <= 10
        assert :ets.info(:osa_memory_vectors_seq, :size) <= 10
      end)
    end

    test "a cap of 0 disables eviction (explicit opt-out, never the default)" do
      with_cap(0, fn ->
        Enum.each(1..60, fn i -> seed("nocap-#{i}", "c#{i}", [1.0]) end)
        assert Search.cache_size() >= 60
      end)

      assert Search.cache_max() == 0
    end

    test "the default cap is a real bound, not disabled" do
      Application.delete_env(:optimal_system_agent, :memory_vector_cache_max)
      assert Search.cache_max() > 0
    end

    test "a garbage cap setting falls back to the default rather than disabling" do
      with_cap(:nonsense, fn -> assert Search.cache_max() > 0 end)
    end
  end

  describe "forget/1 still removes everything for an id" do
    test "the vector row and its LRU bookkeeping both go" do
      seed("forget-me", "some content", [1.0, 2.0])
      assert :ets.lookup(@vector_table, "forget-me") != []

      assert :ok = Search.forget("forget-me")

      assert :ets.lookup(@vector_table, "forget-me") == []
      assert :ets.lookup(:osa_memory_vectors_seq, "forget-me") == []
    end

    test "seq bookkeeping does not outlive a forgotten id" do
      seed("gone", "content", [1.0])
      Search.forget("gone")
      assert :ets.lookup(:osa_memory_vectors_seq, "gone") == []
    end
  end

  describe "coverage nuance: the Consolidator does NOT prune this table" do
    test "an incremental consolidation pass leaves cached vectors untouched" do
      with_cap(0, fn ->
        seed("survives-consolidation", "content that stays", [1.0, 2.0, 3.0])

        # Consolidator is a plain module (not a GenServer) that dedupes
        # Store.Pattern rows via Repo.delete_all. It reaches no ETS table.
        _ = OptimalSystemAgent.Memory.Consolidator.incremental()

        assert :ets.lookup(@vector_table, "survives-consolidation") != [],
               "if this ever starts failing, the Consolidator gained ETS coverage — " <>
                 "update the comments in Memory.Search and Memory.Store to match"
      end)
    end
  end
end
