defmodule OptimalSystemAgent.Memory.SkillGenerator do
  @moduledoc """
  Converts mature SICA patterns into SKILL.md files on disk.

  This is a CAPTURE boundary in the Skills subsystem (see
  `OptimalSystemAgent.Skills`) for the SICA learning path, the analogue of
  `Skills.Capture` for the Voyager `save_skill` path. It exists to STOP a junk
  factory, not to feed one.

  ## Hard gate (default OFF)

  Auto-generation is disabled unless
  `config :optimal_system_agent, auto_skill_generation: true`. Historically this
  path manufactured a SKILL.md from every recurring tool OUTCOME - files like
  `tool-file-read-succeeded`, `io-error-permission-denied-in-file-read`,
  `unknown-error-unclassified-in-memory-recall`. A single tool succeeding or
  failing is telemetry, never a reusable procedure.

  Even when enabled, every candidate pattern must pass `skill_worthy?/1`:

    * its trigger is not a raw `success:` / `error:` tool-outcome key,
    * its category is not a bare success/error class, and
    * its description + trigger + response clear the same high-signal bar as
      `Skills.Capture` (a real trigger and a substantive, multi-step body -
      not a one-liner like `continue`).

  A pattern is considered mature when its occurrence count reaches 5 or more.
  Generated skills are written to ~/.osa/skills/{slug}/SKILL.md in the exact
  format that Tools.Registry.parse_skill_file/1 expects (YAML frontmatter
  between --- markers).

  The `source` frontmatter field carries `auto:{pattern_id}` so that
  skill_exists?/1 can detect duplicates by scanning the skills directory.
  """

  require Logger

  alias OptimalSystemAgent.Memory.Consolidator
  alias OptimalSystemAgent.Skills.Capture

  @maturity_threshold 5

  # Pattern categories that are pure telemetry, never a reusable skill.
  @non_skill_categories ~w(success)

  # Trigger prefixes emitted by `Memory.Learning` for per-tool outcomes. These
  # can never become skills, regardless of how many times they recur.
  @outcome_trigger_prefixes ~w(success: error:)

  # Trivial responses that are a control signal, not a procedure.
  @trivial_responses ~w(continue retry stop skip ok done)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate a SKILL.md from a single pattern struct or map.

  Writes to ~/.osa/skills/{slug}/SKILL.md and hot-reloads the registry.
  Returns {:ok, path} on success or {:error, reason} on failure.
  """
  @spec generate_from_pattern(map()) :: {:ok, String.t()} | {:error, term()}
  def generate_from_pattern(pattern) do
    if skill_worthy?(pattern) do
      do_generate_from_pattern(pattern)
    else
      {:error, :low_signal}
    end
  end

  defp do_generate_from_pattern(pattern) do
    id = pattern[:id] || pattern["id"] || ""
    description = pattern[:description] || pattern["description"] || "unnamed pattern"
    trigger = pattern[:trigger] || pattern["trigger"] || ""
    response = pattern[:response] || pattern["response"] || ""
    category = pattern[:category] || pattern["category"] || "context"
    tags_raw = pattern[:tags] || pattern["tags"] || ""

    slug = slugify(description)
    skills_dir = resolve_skills_dir()
    dir = Path.join(skills_dir, slug)
    path = Path.join(dir, "SKILL.md")

    triggers =
      trigger
      |> String.split(~r/[|,]/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    tags =
      tags_raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    content = render_skill_md(slug, description, triggers, tags, category, id, response)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      Logger.info("[SkillGenerator] wrote skill #{slug} -> #{path}")
      reload_registry()
      {:ok, path}
    else
      {:error, reason} ->
        Logger.warning("[SkillGenerator] failed to write #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[SkillGenerator] generate_from_pattern error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Generate skills for all mature patterns not yet on disk.

  Loads all patterns via Consolidator.load_all/0, filters to those with
  occurrences >= 5, skips any whose skill file already exists, and calls
  generate_from_pattern/1 for the rest.

  Returns {:ok, count} where count is the number of new skills written.
  """
  @spec generate_all_pending() :: {:ok, non_neg_integer()}
  def generate_all_pending do
    if auto_skill_generation_enabled?() do
      patterns = Consolidator.load_all()

      mature =
        Enum.filter(patterns, fn p ->
          occurrences = p[:occurrences] || p["occurrences"] || 0
          occurrences >= @maturity_threshold and skill_worthy?(p)
        end)

      count =
        Enum.reduce(mature, 0, fn pattern, acc ->
          id = pattern[:id] || pattern["id"] || ""

          if skill_exists?(id) do
            acc
          else
            case generate_from_pattern(pattern) do
              {:ok, _path} -> acc + 1
              {:error, _} -> acc
            end
          end
        end)

      {:ok, count}
    else
      # Auto skill generation is OFF by default. A recurring tool outcome is
      # telemetry, not a skill; enabling this requires an explicit operator
      # opt-in AND still passes the skill_worthy?/1 quality gate.
      {:ok, 0}
    end
  rescue
    e ->
      Logger.warning("[SkillGenerator] generate_all_pending error: #{Exception.message(e)}")
      {:ok, 0}
  end

  @doc """
  Check whether a skill already exists for the given pattern ID.

  Scans ~/.osa/skills/ for any SKILL.md containing "source: auto:{pattern_id}"
  in its frontmatter. Returns true if found, false otherwise.
  """
  @spec skill_exists?(String.t()) :: boolean()
  def skill_exists?(pattern_id) when is_binary(pattern_id) and pattern_id != "" do
    skills_dir = resolve_skills_dir()
    marker = "source: auto:#{pattern_id}"

    skills_dir
    |> Path.join("**/SKILL.md")
    |> Path.wildcard()
    |> Enum.any?(fn path ->
      case File.read(path) do
        {:ok, content} -> String.contains?(content, marker)
        _ -> false
      end
    end)
  rescue
    _ -> false
  end

  def skill_exists?(_), do: false

  @doc """
  Convert a description string into a kebab-case directory slug.

  Downcases, replaces spaces and non-alphanumeric characters with hyphens,
  collapses consecutive hyphens, and trims leading/trailing hyphens.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
  end

  def slugify(_), do: "unnamed"

  @doc """
  A pattern is skill-worthy only if it is a genuinely reusable, multi-step
  procedure with a real trigger - never a single tool outcome and never an
  error. Public so the gate can be tested directly.
  """
  @spec skill_worthy?(map()) :: boolean()
  def skill_worthy?(pattern) when is_map(pattern) do
    category = field(pattern, :category, "category")
    description = field(pattern, :description, "description")
    trigger = field(pattern, :trigger, "trigger")
    response = field(pattern, :response, "response")

    cond do
      String.downcase(category) in @non_skill_categories -> false
      outcome_trigger?(trigger) -> false
      String.downcase(String.trim(response)) in @trivial_responses -> false
      true -> high_signal_pattern?(description, trigger, response)
    end
  end

  def skill_worthy?(_), do: false

  # Reuse the Voyager-path capture bar: a real trigger and a substantive,
  # multi-step body. This is what separates a reusable procedure from a
  # one-line note or a restatement of the pattern name.
  defp high_signal_pattern?(description, trigger, response) do
    Capture.validate(%{
      "title" => description,
      "when_to_use" => trigger,
      "description" => description,
      "body" => response
    }) == :ok
  end

  defp outcome_trigger?(trigger) do
    Enum.any?(@outcome_trigger_prefixes, &String.starts_with?(trigger, &1))
  end

  defp field(pattern, atom_key, str_key) do
    (pattern[atom_key] || pattern[str_key] || "") |> to_string()
  end

  defp auto_skill_generation_enabled? do
    Application.get_env(:optimal_system_agent, :auto_skill_generation, false)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_skills_dir do
    Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")
    |> Path.expand()
  end

  defp render_skill_md(slug, description, triggers, tags, category, pattern_id, response) do
    triggers_yaml =
      case triggers do
        [] -> "[]"
        list -> "\n" <> Enum.map_join(list, "\n", fn t -> "  - #{t}" end)
      end

    tags_yaml =
      case tags do
        [] -> "[]"
        list -> "\n" <> Enum.map_join(list, "\n", fn t -> "  - #{t}" end)
      end

    """
    ---
    name: #{slug}
    description: #{description}
    triggers: #{triggers_yaml}
    tools: []
    category: #{category}
    source: auto:#{pattern_id}
    tags: #{tags_yaml}
    ---

    #{response}
    """
  end

  defp reload_registry do
    try do
      OptimalSystemAgent.Tools.Registry.reload_skills()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
