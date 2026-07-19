defmodule OptimalSystemAgent.Memory.QueryExpansion do
  @moduledoc """
  Lightweight, dependency-free query expansion for memory recall.

  Expands a query's keyword set with a small hand-curated synonym dictionary
  plus cheap morphological stemming (plural / gerund / past-tense suffix
  stripping), so the lexical scoring path (`Memory.Scoring`, FTS5/keyword
  overlap) can match memories that use a related but different word than the
  query — e.g. "test" <-> "testing" <-> "spec", "bug" <-> "issue" <-> "defect".

  This is the query-expansion half of hybrid RAG recall (see
  `xai-grok-memory/src/query_expansion.rs`). It is pure and synchronous — no
  LLM call, no network — so it is safe to run on every recall without adding
  latency or a failure mode. It complements (does not replace) the vector-KNN
  half implemented in `Memory.Search`.
  """

  alias OptimalSystemAgent.Memory.Scoring

  # Small hand-curated synonym table covering the domains OSA memories tend
  # to fall into (SICA categories: decision/pattern/lesson/preference/
  # project/context — see Memory module docs). Intentionally short: this is
  # a recall-widening aid, not an ontology.
  @synonyms %{
    "bug" => ~w(issue defect error fault),
    "issue" => ~w(bug problem defect),
    "error" => ~w(bug fault exception failure),
    "fix" => ~w(patch resolve repair correct),
    "fixed" => ~w(patched resolved repaired),
    "test" => ~w(spec check verify testing),
    "testing" => ~w(test spec verification),
    "prefer" => ~w(like want favor choose),
    "prefers" => ~w(likes wants favors chooses),
    "config" => ~w(configuration settings setup),
    "configuration" => ~w(config settings setup),
    "deploy" => ~w(release ship publish),
    "delete" => ~w(remove erase drop),
    "add" => ~w(create insert append),
    "update" => ~w(modify change edit revise),
    "fast" => ~w(quick rapid speedy performant),
    "slow" => ~w(sluggish laggy),
    "database" => ~w(db datastore storage),
    "db" => ~w(database datastore),
    "function" => ~w(method routine func),
    "variable" => ~w(var field),
    "project" => ~w(repo repository codebase),
    "repo" => ~w(repository project codebase),
    "user" => ~w(customer client),
    "always" => ~w(never rule policy must),
    "never" => ~w(always rule policy must),
    "rule" => ~w(policy convention standard),
    "memory" => ~w(recall memories context),
    "code" => ~w(source implementation codebase),
    "style" => ~w(convention format formatting),
    "lint" => ~w(linter linting),
    "auth" => ~w(authentication authorization login),
    "login" => ~w(auth signin authenticate),
    "indentation" => ~w(indent spacing whitespace tabs spaces)
  }

  @doc """
  Expand a list of already-extracted keywords with synonyms + a light stem.

  Original keywords are always included first; duplicates are dropped
  (first occurrence wins), order is otherwise preserved.
  """
  @spec expand_keywords([String.t()]) :: [String.t()]
  def expand_keywords(keywords) when is_list(keywords) do
    keywords
    |> Enum.flat_map(fn kw -> [kw, stem(kw) | synonyms_for(kw)] end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  def expand_keywords(_), do: []

  @doc """
  Expand a raw query string into a widened query string.

  Extracts keywords (via `Memory.Scoring.extract_keywords/1`), expands them,
  and re-joins into a space-separated string suitable for keyword-index or
  FTS5 lookup. Returns the original query unchanged if it yields no
  meaningful keywords (e.g. stop-words only) so callers' empty-query
  short-circuits still apply.
  """
  @spec expand_query(String.t() | nil) :: String.t()
  def expand_query(nil), do: ""
  def expand_query(""), do: ""

  def expand_query(query) when is_binary(query) do
    case query |> Scoring.extract_keywords() |> expand_keywords() do
      [] -> query
      expanded -> Enum.join(expanded, " ")
    end
  end

  def expand_query(_), do: ""

  defp synonyms_for(kw) when is_binary(kw), do: Map.get(@synonyms, kw, [])
  defp synonyms_for(_), do: []

  # Very small, crude suffix-stripping stemmer (not a Porter stemmer) —
  # enough to collapse common morphological variants without a dependency.
  defp stem(kw) when is_binary(kw) do
    cond do
      String.ends_with?(kw, "ies") and String.length(kw) > 4 ->
        String.slice(kw, 0..-4//1) <> "y"

      String.ends_with?(kw, "ing") and String.length(kw) > 5 ->
        String.slice(kw, 0..-4//1)

      String.ends_with?(kw, "ed") and String.length(kw) > 4 ->
        String.slice(kw, 0..-3//1)

      String.ends_with?(kw, "es") and String.length(kw) > 4 ->
        String.slice(kw, 0..-3//1)

      String.ends_with?(kw, "s") and not String.ends_with?(kw, "ss") and
          String.length(kw) > 3 ->
        String.slice(kw, 0..-2//1)

      true ->
        kw
    end
  end

  defp stem(_), do: nil
end
