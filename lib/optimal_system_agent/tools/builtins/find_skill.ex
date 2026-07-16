defmodule OptimalSystemAgent.Tools.Builtins.FindSkill do
  @moduledoc """
  Retrieve relevant procedures from the Voyager-style skill library.

  Matches a free-text query (usually the current task description) against saved
  skills and returns the best matches, incrementing each returned skill's use
  count so the library learns which procedures are actually valuable.

  Flat-layout tool: implements `name/0`, `description/0`, `parameters/0`,
  `execute/1` on top of the defaults injected by `Tools.Behaviour`.
  """

  use OptimalSystemAgent.Tools.Behaviour

  require Logger

  alias OptimalSystemAgent.Store.SkillLibrary

  @default_limit 5

  @impl true
  def name, do: "find_skill"

  @impl true
  def safety, do: :read_only

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def search_hint,
    do: "find recall retrieve a saved reusable procedure skill how-to recipe for this task"

  @impl true
  def description do
    "Search the persistent skill library for verified, reusable procedures relevant " <>
      "to the current task. Call this at the start of a task to reuse past know-how. " <>
      "Pass a query describing what you are trying to do (or a specific slug)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" =>
            "What you are trying to do — matched against skill titles, triggers, and tags"
        },
        "slug" => %{
          "type" => "string",
          "description" => "Optional: fetch one specific skill by its exact slug"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of skills to return (default 5)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(args) when is_map(args) do
    slug = args["slug"] || args[:slug]
    query = to_string(args["query"] || args[:query] || "")
    limit = normalize_limit(args["limit"] || args[:limit])

    cond do
      is_binary(slug) and String.trim(slug) != "" ->
        fetch_by_slug(slug)

      String.trim(query) == "" ->
        {:error, "find_skill requires a non-empty query (or a slug)"}

      true ->
        search(query, limit)
    end
  rescue
    e -> {:error, "find_skill error: #{Exception.message(e)}"}
  end

  def execute(_), do: {:error, "find_skill expects an object of arguments"}

  # ── Private ───────────────────────────────────────────────────────────

  defp fetch_by_slug(slug) do
    case SkillLibrary.get_skill(slug) do
      nil ->
        {:ok, "No skill found with slug '#{slug}'."}

      skill ->
        _ = SkillLibrary.increment_use(skill["slug"])
        {:ok, format_skills([skill])}
    end
  end

  defp search(query, limit) do
    case SkillLibrary.find_skills(query, limit: limit) do
      [] ->
        {:ok, "No matching skills in the library yet for #{inspect(query)}."}

      skills ->
        Enum.each(skills, fn skill -> SkillLibrary.increment_use(skill["slug"]) end)
        {:ok, format_skills(skills)}
    end
  end

  defp normalize_limit(n) when is_integer(n) and n > 0, do: min(n, 20)
  defp normalize_limit(_), do: @default_limit

  defp format_skills(skills) do
    header = "Found #{length(skills)} relevant skill(s):\n"

    body =
      skills
      |> Enum.map_join("\n\n", fn skill ->
        tags = skill["tags"] |> List.wrap() |> Enum.join(", ")

        """
        ## #{skill["title"]} (slug: #{skill["slug"]}, uses: #{skill["uses"] || 0})
        When to use: #{blank_dash(skill["when_to_use"])}
        Description: #{blank_dash(skill["description"])}
        Tags: #{blank_dash(tags)}

        Procedure:
        #{skill["body"]}
        """
        |> String.trim()
      end)

    header <> "\n" <> body
  end

  defp blank_dash(value) do
    case value |> to_string() |> String.trim() do
      "" -> "-"
      s -> s
    end
  end
end
