defmodule OptimalSystemAgent.Tools.Registry.Search do
  @moduledoc """
  Tool and skill search, applicability scoring, and fallback suggestion.

  All functions read from :persistent_term and are safe to call from any
  process without going through the Registry GenServer.
  """

  @language_tool_hints %{
    "python" => ["python"],
    "javascript" => ["node", "javascript", "js"],
    "typescript" => ["node", "typescript", "ts"],
    "ruby" => ["ruby"],
    "elixir" => ["elixir", "mix"],
    "go" => ["golang", "go_"],
    "rust" => ["rust", "cargo"]
  }

  # ── Keyword Search ───────────────────────────────────────────────────

  @doc "Search existing tools and skills by keyword matching against names and descriptions."
  @spec search(map(), map(), String.t()) :: list({String.t(), String.t(), float()})
  def search(builtin_tools, skills, query) do
    keywords = extract_keywords(query)

    if keywords == [] do
      []
    else
      builtin_results =
        Enum.map(builtin_tools, fn {name, mod} ->
          desc = mod.description()
          score = compute_relevance(keywords, name, desc)
          {name, desc, score}
        end)

      skill_results =
        Enum.map(skills, fn {name, skill} ->
          desc = skill.description
          score = compute_relevance(keywords, name, desc)
          {name, desc, score}
        end)

      (builtin_results ++ skill_results)
      |> Enum.filter(fn {_name, _desc, score} -> score > 0.0 end)
      |> Enum.sort_by(fn {_name, _desc, score} -> score end, :desc)
    end
  end

  # ── Applicability Scoring ────────────────────────────────────────────

  @doc """
  Filter the full tool list to only tools relevant to the current session context.

  `context` is a map with optional keys:
    - `:language`  — detected language (e.g. "python", "elixir", "javascript")
    - `:framework` — detected framework (e.g. "phoenix", "react", "django")
    - `:history`   — list of recently used tool names (strings)

  Returns a list of tool maps in relevance order, same shape as list_tools_direct/0.
  """
  @spec filter_applicable_tools(map(), [map()]) :: [map()]
  def filter_applicable_tools(context, all_tools) do
    language = Map.get(context, :language, nil)
    framework = Map.get(context, :framework, nil)
    recent = Map.get(context, :history, []) |> MapSet.new()

    scored =
      Enum.map(all_tools, fn tool ->
        score = tool_applicability_score(tool, language, framework, recent)
        {tool, score}
      end)

    scored
    |> Enum.sort_by(fn {_tool, score} -> -score end)
    |> Enum.map(fn {tool, _score} -> tool end)
  end

  # ── Fallback Suggestion ──────────────────────────────────────────────

  @doc """
  Suggest an alternative tool when `failed_tool` fails.

  Returns `{:ok, alternative_tool_name}` when a known fallback exists,
  or `:no_alternative` when no substitution is available.
  """
  @spec suggest_fallback(String.t(), map()) :: {:ok, String.t()} | :no_alternative
  def suggest_fallback(failed_tool, builtin_tools) do
    fallbacks = %{
      "shell_execute" => "file_read",
      "web_search" => "web_fetch",
      "web_fetch" => "web_search",
      "file_write" => "multi_file_edit",
      "multi_file_edit" => "file_write",
      "file_edit" => "multi_file_edit",
      "semantic_search" => "session_search",
      "session_search" => "memory_recall"
    }

    case Map.get(fallbacks, failed_tool) do
      nil ->
        :no_alternative

      alt ->
        if Map.has_key?(builtin_tools, alt) do
          require Logger
          Logger.info("[Tools.Registry] Fallback for '#{failed_tool}': '#{alt}'")
          {:ok, alt}
        else
          :no_alternative
        end
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp tool_applicability_score(tool, language, framework, recent_set) do
    name = tool.name
    desc = String.downcase(tool.description)

    recent_bonus = if MapSet.member?(recent_set, name), do: 0.3, else: 0.0

    language_score =
      cond do
        is_nil(language) ->
          0.0

        String.contains?(desc, language) or String.contains?(name, language) ->
          0.4

        language_conflicts?(name, language) ->
          -0.2

        true ->
          0.0
      end

    framework_score =
      cond do
        is_nil(framework) ->
          0.0

        String.contains?(desc, framework) or String.contains?(name, framework) ->
          0.2

        true ->
          0.0
      end

    recent_bonus + language_score + framework_score
  end

  defp language_conflicts?(tool_name, language) do
    lang_lower = String.downcase(language)
    own_hints = Map.get(@language_tool_hints, lang_lower, [])

    Enum.any?(@language_tool_hints, fn {lang, hints} ->
      lang != lang_lower and
        Enum.any?(hints, fn hint -> String.contains?(tool_name, hint) end) and
        own_hints != []
    end)
  end

  defp extract_keywords(text) do
    stop_words =
      MapSet.new(~w(
        a an the is are was were be been being have has had do does did will would could
        should may might shall can need dare ought used to of in for on with at by from
        as into through during before after above below between out off over under again
        further then once that this these those i me my we our you your it its and but
        or nor not so if when what which who how all each every both few more most other
        some such no only same than too very just because about up
      ))

    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn word -> MapSet.member?(stop_words, word) or String.length(word) < 2 end)
    |> Enum.uniq()
  end

  defp compute_relevance(keywords, name, description) do
    name_lower = String.downcase(name)
    desc_lower = String.downcase(description)

    name_tokens =
      name_lower
      |> String.replace(~r/[-_]/, " ")
      |> String.split(~r/\s+/, trim: true)

    total_keywords = length(keywords)

    if total_keywords == 0 do
      0.0
    else
      name_exact_matches = Enum.count(keywords, fn kw -> name_lower == kw end)

      name_token_matches =
        Enum.count(keywords, fn kw ->
          Enum.any?(name_tokens, fn token -> token == kw end)
        end)

      name_substring_matches =
        Enum.count(keywords, fn kw -> String.contains?(name_lower, kw) end)

      desc_matches = Enum.count(keywords, fn kw -> String.contains?(desc_lower, kw) end)

      raw_score =
        (name_exact_matches * 1.0 +
           name_token_matches * 0.7 +
           name_substring_matches * 0.5 +
           desc_matches * 0.3) / total_keywords

      min(raw_score, 1.0) |> Float.round(2)
    end
  end
end
