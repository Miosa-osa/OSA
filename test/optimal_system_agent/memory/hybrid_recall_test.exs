defmodule OptimalSystemAgent.Memory.HybridRecallTest do
  @moduledoc """
  Focused tests for the P1 hybrid-RAG memory recall upgrade:

    - `Memory.Search`         — cosine-similarity vector KNN
    - `Memory.MMR`            — Maximal Marginal Relevance diversity re-rank
    - `Memory.QueryExpansion` — synonym / stem query widening
    - `Memory.recall_hybrid/2` — the fused, drop-in public entry point

  `Memory.Search.knn/2` normally embeds candidates over the network (local
  Ollama `/api/embeddings`). To keep these tests fast/deterministic and
  independent of whether an Ollama instance happens to be running, the vector
  tests seed `Search`'s ETS embedding cache directly with known vectors
  (exactly what a successful `embed_cached/2` call would have cached) rather
  than mocking HTTP. This tests the KNN/MMR *algorithms* precisely — the
  live-network embedding call itself is exercised by `Memory.Search.embed/1`
  degrading to `{:error, _}` when unreachable, covered by the fallback test
  below.

  async: false — shares the `Memory.Store` singleton GenServer and process
  application env for the `recall_hybrid/2` integration test.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Memory.{Search, MMR, QueryExpansion}

  @vector_table :osa_memory_vectors

  # Prime the Search ETS cache exactly as `embed_cached/2` would after a
  # successful embed, without touching the network.
  defp seed_vector(id, content, vector) do
    # Ensure the table exists. embed_cached/2 always creates it (even on a
    # failed embed) before returning, so a throwaway call is enough.
    Search.embed_cached(id, "unused-#{id}")
    :ets.insert(@vector_table, {id, :erlang.phash2(content), vector})
  end

  # ---------------------------------------------------------------------------
  # Memory.Search — vector KNN finds semantically-related, lexically-different
  # entries that pure keyword overlap would score 0.0 (miss entirely).
  # ---------------------------------------------------------------------------

  describe "Search.knn/2 — semantic recall beyond keyword overlap" do
    test "ranks a lexically-different but semantically-close entry above an unrelated one" do
      # No shared keywords with "deployment rollback procedure" at all — pure
      # Jaccard keyword-overlap scoring would give this 0.0 relevance.
      close = %{id: "sem-close", content: "how we undo a bad release in production"}
      unrelated = %{id: "sem-unrelated", content: "favorite pizza toppings for the team lunch"}

      query_vec = [1.0, 0.0, 0.0]
      # Semantically close: nearly parallel to the query vector.
      seed_vector("sem-close", close.content, [0.95, 0.1, 0.0])
      # Unrelated: orthogonal.
      seed_vector("sem-unrelated", unrelated.content, [0.0, 1.0, 0.0])

      {scored, embeddings} = Search.knn(query_vec, [close, unrelated])

      assert [{top_score, %{id: "sem-close"}}, {bottom_score, %{id: "sem-unrelated"}}] = scored
      assert top_score > bottom_score
      assert top_score > 0.8
      assert bottom_score < 0.1
      assert Map.has_key?(embeddings, "sem-close")
      assert Map.has_key?(embeddings, "sem-unrelated")

      # Confirm the premise: keyword overlap between the query text and the
      # "close" entry really is zero, i.e. keyword-only recall would have
      # missed it entirely — vector KNN is what surfaces it.
      query_keywords =
        OptimalSystemAgent.Memory.Scoring.extract_keywords("deployment rollback procedure")

      entry_keywords = OptimalSystemAgent.Memory.Scoring.extract_keywords(close.content)

      assert OptimalSystemAgent.Memory.Scoring.keyword_overlap(query_keywords, entry_keywords) ==
               0.0
    end

    test "cosine_similarity/2 is 1.0 for identical vectors and 0.0 for orthogonal ones" do
      assert Search.cosine_similarity([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]) == 1.0
      assert Search.cosine_similarity([1.0, 0.0], [0.0, 1.0]) == 0.0
      assert Search.cosine_similarity([], []) == 0.0
      assert Search.cosine_similarity([1.0, 2.0], [1.0, 2.0, 3.0]) == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Memory.MMR — diversity re-rank drops a near-duplicate in favour of a more
  # distinct, still-relevant candidate.
  # ---------------------------------------------------------------------------

  describe "MMR.rerank/2 — near-duplicate suppression" do
    test "prefers a distinct lower-scored candidate over a near-duplicate of the top pick" do
      top = %{id: "a", content: "prefer tabs over spaces", keywords: "tabs,spaces,prefer"}
      # Near-identical rewording of `top` — same fact, high embedding similarity.
      near_dup = %{
        id: "b",
        content: "tabs are preferred over spaces",
        keywords: "tabs,spaces,prefer"
      }

      # Distinct fact, lower relevance score but NOT similar to `top`.
      distinct = %{
        id: "c",
        content: "always run tests before merging",
        keywords: "always,tests,merging"
      }

      scored = [
        {0.90, top},
        {0.85, near_dup},
        {0.60, distinct}
      ]

      embeddings = %{
        "a" => [1.0, 0.0],
        "b" => [0.99, 0.05],
        "c" => [0.0, 1.0]
      }

      result = MMR.rerank(scored, limit: 2, lambda: 0.5, embeddings: embeddings)

      assert length(result) == 2
      ids = Enum.map(result, & &1.id)

      assert "a" in ids, "top-scored entry must always be selected first"
      refute "b" in ids, "near-duplicate of the top pick must be dropped by diversity re-rank"
      assert "c" in ids, "distinct-but-lower-scored entry must fill the second slot instead"
    end

    test "pure relevance ranking (lambda: 1.0) ignores diversity entirely" do
      scored = [{0.9, %{id: "a"}}, {0.85, %{id: "b"}}, {0.1, %{id: "c"}}]
      embeddings = %{"a" => [1.0, 0.0], "b" => [1.0, 0.0], "c" => [0.0, 1.0]}

      result = MMR.rerank(scored, limit: 2, lambda: 1.0, embeddings: embeddings)
      assert Enum.map(result, & &1.id) == ["a", "b"]
    end

    test "falls back to keyword Jaccard diversity when no embeddings are supplied" do
      a = %{id: "a", keywords: "tabs,spaces,prefer,indent"}
      # Near-duplicate keyword set.
      b = %{id: "b", keywords: "tabs,spaces,prefer,style"}
      # Disjoint keyword set.
      c = %{id: "c", keywords: "always,tests,merging"}

      result = MMR.rerank([{0.9, a}, {0.85, b}, {0.6, c}], limit: 2, lambda: 0.5)

      ids = Enum.map(result, & &1.id)
      assert "a" in ids
      refute "b" in ids
      assert "c" in ids
    end

    test "empty candidate list returns empty" do
      assert MMR.rerank([], limit: 5) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Memory.QueryExpansion
  # ---------------------------------------------------------------------------

  describe "QueryExpansion" do
    test "expand_keywords/1 adds known synonyms and keeps the original term" do
      expanded = QueryExpansion.expand_keywords(["bug"])
      assert "bug" in expanded
      assert "issue" in expanded
      assert "defect" in expanded
    end

    test "expand_keywords/1 stems simple morphological variants" do
      expanded = QueryExpansion.expand_keywords(["testing"])
      assert "test" in expanded
    end

    test "expand_query/1 returns the original query when it has no keywords" do
      assert QueryExpansion.expand_query("the a an") == "the a an"
      assert QueryExpansion.expand_query("") == ""
      assert QueryExpansion.expand_query(nil) == ""
    end

    test "expand_query/1 widens a real query" do
      expanded = QueryExpansion.expand_query("fix the login bug")
      assert expanded =~ "login"
      assert expanded =~ "bug"
      assert expanded =~ "issue"
    end
  end

  # ---------------------------------------------------------------------------
  # Memory.recall_hybrid/2 — graceful fallback when embeddings unavailable
  # ---------------------------------------------------------------------------

  describe "Memory.recall_hybrid/2 graceful degradation" do
    setup do
      previous = Application.get_env(:optimal_system_agent, :embedding_provider)
      Application.put_env(:optimal_system_agent, :embedding_provider, :none)

      on_exit(fn ->
        if previous do
          Application.put_env(:optimal_system_agent, :embedding_provider, previous)
        else
          Application.delete_env(:optimal_system_agent, :embedding_provider)
        end
      end)

      :ok
    end

    test "never raises and returns keyword-scored results when no embedding provider is configured" do
      refute Search.available?()

      assert {:ok, saved} =
               Memory.save("Hybridrecalltest always prefers rebase over merge for git history",
                 category: :decision
               )

      assert {:ok, results} = Memory.recall_hybrid("hybridrecalltest rebase merge", limit: 5)
      assert is_list(results)
      assert Enum.any?(results, &(&1.id == saved.id))
    end

    test "empty/stop-word-only query returns {:ok, []} without table-scanning" do
      assert {:ok, []} = Memory.recall_hybrid("the a an")
    end
  end

  describe "Memory.recall_hybrid/2 signature parity with recall/2" do
    test "accepts the same limit/category/scope/min_score opts and returns {:ok, [entry,...]}" do
      assert {:ok, _entry} =
               Memory.save("Sigparitytest uses PostgreSQL for the primary datastore",
                 category: :project
               )

      assert {:ok, results} =
               Memory.recall_hybrid("sigparitytest postgresql datastore",
                 limit: 3,
                 category: :project,
                 scope: :global,
                 min_score: 0.0
               )

      assert is_list(results)
      assert length(results) <= 3
    end
  end
end
