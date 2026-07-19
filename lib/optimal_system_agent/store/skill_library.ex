defmodule OptimalSystemAgent.Store.SkillLibrary do
  @moduledoc """
  Voyager-style skill library — a persistent store of verified, reusable
  procedures that accumulate across sessions and projects.

  This is the STORE stage of the Skills subsystem (see
  `OptimalSystemAgent.Skills` for the full capture -> store -> rank -> surface ->
  invoke design). Persistence only: admission policy is delegated to
  `Skills.Capture` and relevance ranking to `Skills.Ranker`.

  Unlike the SKILL.md skills discovered by `Tools.Registry` (author-curated,
  shipped with the agent), skill-library entries are *learned at runtime*: the
  agent records a procedure it has verified works, tags it, and later retrieves
  it when a similar task appears. Skills compound over time — the more the agent
  runs, the larger and more useful the library becomes.

  ## Storage

  Each skill is a single JSON file at `~/.osa/skills/<slug>.json`. The registry's
  `SkillLoader` only scans *sub-directories* containing a `SKILL.md`, so these
  flat `.json` files never collide with markdown-defined skills.

  A skill map has the shape:

      %{
        "slug"        => "restart-osa-gateway",
        "title"       => "Restart the OSA gateway safely",
        "description" => "Kill and restart the gateway without losing sessions",
        "when_to_use" => "When the gateway is unresponsive or port 18789 is stuck",
        "body"        => "1. ss -ltnp | rg 18789 ...",
        "tags"        => ["gateway", "ops"],
        "created_at"  => "2026-07-16T09:00:00Z",
        "updated_at"  => "2026-07-16T09:00:00Z",
        "uses"        => 3
      }
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Skills.Capture
  alias OptimalSystemAgent.Skills.Ranker

  @type skill :: %{optional(String.t()) => term()}

  @default_dir "~/.osa/skills"

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Upsert a skill. Accepts a map with string or atom keys.

  A `slug` is derived from the title when not supplied. Re-saving an existing
  slug preserves `created_at` and the accumulated `uses` count while refreshing
  every other field and bumping `updated_at`.
  """
  @spec save_skill(map()) :: {:ok, skill()} | {:error, String.t()}
  def save_skill(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    title = attrs["title"] |> to_string() |> String.trim()

    # CAPTURE gate: admit only high-signal, reusable procedures. Trivial
    # one-offs are rejected before they can pollute the store or ranking.
    case Capture.validate(attrs) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        slug = normalize_slug(attrs["slug"] || title)
        existing = get_skill(slug)
        now = now_iso()

        skill = %{
          "slug" => slug,
          "title" => title,
          "description" => to_string(attrs["description"] || ""),
          "when_to_use" => to_string(attrs["when_to_use"] || ""),
          "body" => to_string(attrs["body"]),
          "tags" => normalize_tags(attrs["tags"]),
          "created_at" => (existing && existing["created_at"]) || now,
          "updated_at" => now,
          "uses" => (existing && existing["uses"]) || 0
        }

        write_skill(slug, skill)
    end
  end

  def save_skill(_), do: {:error, "skill attrs must be a map"}

  @doc """
  Find skills relevant to a free-text query. Delegates ordering to
  `Skills.Ranker`, which scores by fuzzy field-weighted relevance to the query
  and then boosts by recency and usage. Relevance is the gate — unrelated skills
  never surface.

  Options:
    * `:limit` — max results (default 5)
  """
  @spec find_skills(String.t(), keyword()) :: [skill()]
  def find_skills(query, opts \\ [])

  def find_skills(query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 5)
    Ranker.rank(list_skills(), query, limit: limit)
  end

  def find_skills(_, _), do: []

  @doc "Fetch a single skill by slug, or nil if absent."
  @spec get_skill(String.t()) :: skill() | nil
  def get_skill(slug) when is_binary(slug) do
    path = skill_path(normalize_slug(slug))

    with {:ok, json} <- File.read(path),
         {:ok, skill} <- Jason.decode(json) do
      skill
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def get_skill(_), do: nil

  @doc "List every stored skill, most-recently-updated first."
  @spec list_skills() :: [skill()]
  def list_skills do
    dir = skills_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn file ->
        case File.read(Path.join(dir, file)) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, skill} when is_map(skill) -> skill
              _ -> nil
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn skill -> skill["updated_at"] || skill["created_at"] || "" end, :desc)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[skill_library] list_skills failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Increment the `uses` counter for a skill (records that it was retrieved and
  applied). Returns the updated skill or `{:error, reason}`.
  """
  @spec increment_use(String.t()) :: {:ok, skill()} | {:error, String.t()}
  def increment_use(slug) when is_binary(slug) do
    case get_skill(slug) do
      nil ->
        {:error, "no skill with slug #{inspect(slug)}"}

      skill ->
        updated = Map.update(skill, "uses", 1, &((&1 || 0) + 1))
        write_skill(skill["slug"] || normalize_slug(slug), updated, emit: false)
    end
  end

  def increment_use(_), do: {:error, "slug must be a string"}

  # ── Private ───────────────────────────────────────────────────────────

  @spec write_skill(String.t(), skill(), keyword()) :: {:ok, skill()} | {:error, String.t()}
  defp write_skill(slug, skill, opts \\ []) do
    dir = skills_dir()
    File.mkdir_p!(dir)
    path = skill_path(slug)

    case Jason.encode(skill, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)

        if Keyword.get(opts, :emit, true) do
          emit_saved(skill)
        end

        {:ok, skill}

      {:error, reason} ->
        {:error, "failed to encode skill: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.warning("[skill_library] write failed for #{slug}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp emit_saved(skill) do
    Bus.emit(:system_event, %{
      event: :skill_library_saved,
      slug: skill["slug"],
      title: skill["title"],
      uses: skill["uses"]
    })

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @spec normalize_slug(String.t()) :: String.t()
  defp normalize_slug(value) do
    slug =
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    case slug do
      "" -> "skill-" <> Integer.to_string(System.unique_integer([:positive]))
      s -> s
    end
  end

  defp normalize_tags(nil), do: []

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tags(tags) when is_binary(tags) do
    tags
    |> String.split(~r/[,\s]+/, trim: true)
    |> normalize_tags()
  end

  defp normalize_tags(_), do: []

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp skill_path(slug), do: Path.join(skills_dir(), slug <> ".json")

  defp skills_dir do
    Application.get_env(:optimal_system_agent, :skills_dir, @default_dir)
    |> Path.expand()
  end
end
