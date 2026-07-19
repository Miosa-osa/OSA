defmodule OptimalSystemAgent.Memory.SearchPersistenceTest do
  @moduledoc """
  Tests for the durable (SQLite-persisted) vector store backing
  `Memory.Search` — the P1 gap-fix that replaced the ephemeral-only ETS
  cache (`memory/search.ex`, migration
  `priv/repo/migrations/20260719000001_create_memory_vectors.exs`).

  Covers:
    - a vector persists to SQLite and survives a simulated restart (ETS
      cleared, no live embed call) by loading straight from the DB row
    - a content change invalidates the persisted vector and forces a
      re-embed instead of serving stale data
    - graceful degradation to error (not a crash) when no embedding
      provider is configured, even with a persisted-but-stale row present

  async: false — touches the shared `:osa_memory_vectors` ETS table and the
  shared `Memory.VectorEntry` SQLite table.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Memory.Search
  alias OptimalSystemAgent.Memory.VectorEntry
  alias OptimalSystemAgent.Store.Repo

  @vector_table :osa_memory_vectors

  setup_all do
    # Migrations run synchronously inside Application.start/2 before mix test
    # ever hands control to ExUnit, but on a loaded box the very first query
    # against a freshly-created SQLite file can still race the WAL becoming
    # readable. Retry briefly rather than let the first test in the file take
    # a spurious hit.
    wait_for_table_ready()
    :ok
  end

  defp wait_for_table_ready(attempts \\ 20)
  defp wait_for_table_ready(0), do: :ok

  defp wait_for_table_ready(attempts) do
    Repo.get(VectorEntry, "__wait_for_table_ready__")
    :ok
  rescue
    _ ->
      Process.sleep(50)
      wait_for_table_ready(attempts - 1)
  end

  setup do
    previous = Application.get_env(:optimal_system_agent, :embedding_provider)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_system_agent, :embedding_provider, previous)
      else
        Application.delete_env(:optimal_system_agent, :embedding_provider)
      end
    end)

    :ok
  end

  # Directly writes a persisted vector row, bypassing embed/1 entirely —
  # exactly the shape `Memory.Search`'s internal `persist/3` would have
  # written after a successful live embed.
  defp seed_persisted_row(id, content, vector) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    hash = :erlang.phash2(content)

    attrs = %{
      id: id,
      content_hash: hash,
      embedding: Jason.encode!(vector),
      dim: length(vector),
      model: "test-model",
      created_at: now,
      updated_at: now
    }

    case Repo.get(VectorEntry, id) do
      nil -> %VectorEntry{} |> VectorEntry.changeset(attrs) |> Repo.insert!()
      existing -> existing |> VectorEntry.changeset(attrs) |> Repo.update!()
    end

    :ok
  end

  defp clear_ets_entry(id) do
    try do
      :ets.delete(@vector_table, id)
    rescue
      ArgumentError -> :ok
    end
  end

  defp delete_persisted_row(id) do
    case Repo.get(VectorEntry, id) do
      nil -> :ok
      row -> Repo.delete!(row)
    end
  end

  describe "vector persistence survives a simulated restart" do
    test "loads straight from the persisted row after ETS is cleared, without re-embedding" do
      id = "persist-restart-#{System.unique_integer([:positive])}"
      content = "always index the memory content column for restart survival"
      vector = [0.11, 0.22, 0.33]

      seed_persisted_row(id, content, vector)
      # Simulate a node restart: the ETS cache is empty for this id (a fresh
      # boot's ETS table has nothing in it), but the SQLite row survives.
      clear_ets_entry(id)
      on_exit(fn -> delete_persisted_row(id) end)

      # Disable the embedding provider entirely so ANY code path that fell
      # through to a live embed() call would return {:error, :embeddings_unavailable}
      # instead of a vector — proving the returned vector could only have
      # come from the persisted row, not a re-embed.
      Application.put_env(:optimal_system_agent, :embedding_provider, :none)
      refute Search.available?()

      assert {:ok, ^vector} = Search.embed_cached(id, content)

      # And it's now warm in ETS again (write-through on load).
      assert [{^id, _hash, ^vector}] = :ets.lookup(@vector_table, id)
    end

    test "a second call after warming does not touch SQLite again (ETS hit)" do
      id = "persist-ets-hit-#{System.unique_integer([:positive])}"
      content = "ets should short circuit after the first disk load"
      vector = [1.0, 2.0, 3.0]

      seed_persisted_row(id, content, vector)
      clear_ets_entry(id)
      on_exit(fn -> delete_persisted_row(id) end)

      assert {:ok, ^vector} = Search.embed_cached(id, content)

      # Delete the persisted row entirely — if the next call still succeeds
      # with the same vector, it MUST have come from the (now-warm) ETS
      # cache, not SQLite.
      delete_persisted_row(id)
      assert {:ok, ^vector} = Search.embed_cached(id, content)
    end
  end

  describe "content-change invalidation" do
    test "a changed content hash is treated as a miss and does not serve the stale vector" do
      id = "persist-stale-#{System.unique_integer([:positive])}"
      old_content = "the api uses rest endpoints"
      new_content = "the api uses graphql endpoints now"
      stale_vector = [9.0, 9.0, 9.0]

      seed_persisted_row(id, old_content, stale_vector)
      clear_ets_entry(id)
      on_exit(fn -> delete_persisted_row(id) end)

      # No embedding provider configured, so the forced re-embed (triggered
      # by the hash mismatch) fails cleanly — proving the stale vector was
      # NOT served, rather than silently returning wrong data.
      Application.put_env(:optimal_system_agent, :embedding_provider, :none)

      assert {:error, _} = Search.embed_cached(id, new_content)
    end
  end

  describe "graceful degradation" do
    test "embed_cached/2 never raises when the embedding provider is disabled" do
      Application.put_env(:optimal_system_agent, :embedding_provider, :none)
      id = "persist-degrade-#{System.unique_integer([:positive])}"

      assert {:error, _} = Search.embed_cached(id, "some brand new never-seen content")
    end
  end

  describe "forget/1 removes both the ETS and persisted copies" do
    test "a forgotten id is neither in ETS nor SQLite afterwards" do
      id = "persist-forget-#{System.unique_integer([:positive])}"
      content = "temporary fact to be forgotten"
      vector = [0.5, 0.5]

      seed_persisted_row(id, content, vector)
      Search.embed_cached(id, content)

      assert :ets.lookup(@vector_table, id) != []
      assert Repo.get(VectorEntry, id) != nil

      assert :ok = Search.forget(id)

      assert :ets.lookup(@vector_table, id) == []
      assert Repo.get(VectorEntry, id) == nil
    end
  end
end
