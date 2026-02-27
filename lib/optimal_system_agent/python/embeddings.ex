defmodule OptimalSystemAgent.Python.Embeddings do
  @moduledoc """
  Public API for semantic memory search via the Python sidecar.

  Delegates to `Python.Sidecar` for embedding generation and vector search.
  Falls back gracefully to keyword search when the sidecar is unavailable.
  """
  require Logger

  alias OptimalSystemAgent.Python.Sidecar

  @doc """
  Generate an embedding vector for the given text.

  Returns `{:ok, [float]}` or `{:error, reason}`.
  """
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, atom()}
  def embed(text) when is_binary(text) do
    case Sidecar.request("embed", %{"text" => text}) do
      {:ok, %{"embedding" => embedding}} when is_list(embedding) ->
        {:ok, embedding}

      {:ok, other} ->
        {:error, {:unexpected_result, other}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Semantic search across memory entries.

  Sends the query to the Python sidecar which computes embeddings and
  returns the top-k most similar entries by cosine similarity.

  ## Options
    - `:top_k` — max results (default 10)
    - `:max_tokens` — token budget for results (default 2000)

  Returns `{:ok, results}` where results is a list of `%{"id" => ..., "score" => ...}`,
  or `{:error, reason}` if the sidecar is unavailable.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def search(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 10)

    case Sidecar.request("search", %{"query" => query, "top_k" => top_k}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {:ok, results}

      {:ok, other} ->
        {:error, {:unexpected_result, other}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Reindex all memory entries in the Python sidecar's vector store.

  Pass a list of `%{id: "...", content: "..."}` maps.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  @spec reindex([map()]) :: {:ok, non_neg_integer()} | {:error, atom()}
  def reindex(entries) when is_list(entries) do
    serialized =
      Enum.map(entries, fn entry ->
        %{
          "id" => to_string(entry[:id] || entry["id"] || ""),
          "content" => to_string(entry[:content] || entry["content"] || "")
        }
      end)

    case Sidecar.request("reindex", %{"entries" => serialized}, 60_000) do
      {:ok, %{"indexed" => count}} when is_integer(count) ->
        {:ok, count}

      {:ok, other} ->
        {:error, {:unexpected_result, other}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Compute cosine similarity between two texts.

  Returns `{:ok, float}` (0.0 to 1.0) or `{:error, reason}`.
  """
  @spec similarity(String.t(), String.t()) :: {:ok, float()} | {:error, atom()}
  def similarity(text_a, text_b) do
    case Sidecar.request("similarity", %{"text_a" => text_a, "text_b" => text_b}) do
      {:ok, %{"similarity" => score}} when is_number(score) ->
        {:ok, score}

      {:ok, other} ->
        {:error, {:unexpected_result, other}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Check if the Python sidecar is available for semantic search."
  @spec available?() :: boolean()
  def available? do
    Sidecar.available?()
  catch
    _, _ -> false
  end
end
