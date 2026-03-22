defmodule OptimalSystemAgent.Tools.Registry.SkillLoader do
  @moduledoc """
  Loads and parses SKILL.md skill definitions from priv/skills/ and ~/.osa/skills/.

  Built-in skills are loaded from the application's priv/skills/ directory tree.
  User skills are loaded from the directory configured in :skills_dir (default
  ~/.osa/skills/). User skills take precedence over built-in skills with the
  same name.
  """

  require Logger

  @known_skill_categories ~w(core automation reasoning)

  defp skills_dir, do: Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Load all skills: built-in (priv/skills/) merged with user (~/.osa/skills/).
  User skills override built-in skills with the same name.
  """
  @spec load_skills() :: map()
  def load_skills do
    priv_dir = resolve_priv_skills_path()

    priv_skills =
      load_skill_definitions()
      |> Enum.reduce(%{}, fn skill, acc ->
        abs_path =
          if priv_dir, do: Path.join(priv_dir, skill.source_path), else: skill.source_path

        entry = %{
          name: skill.name,
          description: skill.description,
          triggers: skill.triggers,
          tools: [],
          path: abs_path
        }

        Map.put(acc, skill.name, entry)
      end)

    user_dir = Path.expand(skills_dir())

    user_skills =
      if File.dir?(user_dir) do
        user_dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(user_dir, &1)))
        |> Enum.reduce(%{}, fn skill_dir, acc ->
          skill_file = Path.join([user_dir, skill_dir, "SKILL.md"])

          if File.exists?(skill_file) do
            case parse_skill_file(skill_file) do
              {:ok, skill} -> Map.put(acc, skill.name, skill)
              :error -> acc
            end
          else
            acc
          end
        end)
      else
        %{}
      end

    Map.merge(priv_skills, user_skills)
  end

  @doc """
  Discover all skill definitions from priv/skills/.

  Walks the directory tree, finds all .md files, parses YAML frontmatter, and
  returns a list of skill definition maps. Returns [] when the directory is
  absent.

  Each map contains: :name, :description, :category, :triggers, :priority,
  :instructions, :source_path, :metadata.
  """
  @spec load_skill_definitions() :: [map()]
  def load_skill_definitions do
    skills_path = resolve_priv_skills_path()

    if skills_path && File.dir?(skills_path) do
      skills_path
      |> find_md_files()
      |> Enum.map(fn path -> parse_skill_definition(path, skills_path) end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  # ── Private: SKILL.md Parsing ─────────────────────────────────────────

  defp parse_skill_file(path) do
    content = File.read!(path)

    case String.split(content, "---", parts: 3) do
      ["", frontmatter, _body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, meta} ->
            {:ok,
             %{
               name: meta["name"] || Path.basename(Path.dirname(path)),
               description: meta["description"] || "",
               triggers: meta["triggers"] || [],
               tools: meta["tools"] || [],
               path: path
             }}

          _ ->
            :error
        end

      _ ->
        {:ok,
         %{
           name: Path.basename(Path.dirname(path)),
           description: String.slice(content, 0, 100),
           triggers: [],
           tools: [],
           path: path
         }}
    end
  end

  defp parse_skill_definition(path, base_path) do
    content = File.read!(path)
    relative_path = Path.relative_to(path, base_path)
    category = derive_category(relative_path)

    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, meta} ->
            build_skill_def(meta, body, relative_path, category)

          {:error, reason} ->
            Logger.debug(
              "[Tools.Registry] YAML frontmatter parse failed for #{relative_path}: #{inspect(reason)} — treating as plain content"
            )

            build_skill_def_from_content(content, relative_path, category)

          _ ->
            build_skill_def_from_content(content, relative_path, category)
        end

      _ ->
        build_skill_def_from_content(content, relative_path, category)
    end
  rescue
    e ->
      Logger.warning("Failed to parse skill definition at #{path}: #{inspect(e)}")
      nil
  end

  defp build_skill_def(meta, body, relative_path, category) do
    name =
      meta["name"] ||
        meta["skill_name"] ||
        meta["skill"] ||
        derive_name_from_path(relative_path)

    triggers = normalize_triggers(meta)

    priority =
      case meta["priority"] do
        p when is_integer(p) -> p
        p when is_binary(p) -> parse_priority(p)
        _ -> 5
      end

    standard_keys =
      ~w(name skill_name skill description trigger triggers trigger_keywords priority tools)

    metadata = Map.drop(meta, standard_keys)

    %{
      name: to_string(name),
      description: to_string(meta["description"] || ""),
      category: category,
      triggers: triggers,
      priority: priority,
      instructions: String.trim(body),
      source_path: relative_path,
      metadata: metadata
    }
  end

  defp build_skill_def_from_content(content, relative_path, category) do
    %{
      name: derive_name_from_path(relative_path),
      description: content |> String.slice(0, 100) |> String.trim(),
      category: category,
      triggers: [],
      priority: 5,
      instructions: content,
      source_path: relative_path,
      metadata: %{}
    }
  end

  defp parse_priority(str) do
    case Integer.parse(str) do
      {n, ""} ->
        n

      _ ->
        case String.downcase(String.trim(str)) do
          "critical" -> 0
          "high" -> 1
          "medium" -> 3
          "low" -> 7
          _ -> 5
        end
    end
  end

  defp normalize_triggers(meta) do
    cond do
      is_list(meta["triggers"]) ->
        List.flatten(meta["triggers"]) |> Enum.map(&to_string/1)

      is_list(meta["trigger_keywords"]) ->
        List.flatten(meta["trigger_keywords"]) |> Enum.map(&to_string/1)

      is_binary(meta["trigger"]) ->
        meta["trigger"]
        |> String.split(~r/[|,]/, trim: true)
        |> Enum.map(&String.trim/1)

      true ->
        []
    end
  end

  defp derive_category(relative_path) do
    parts = Path.split(relative_path)

    case parts do
      [dir, _file] when dir in @known_skill_categories -> dir
      [_dir, "SKILL.md"] -> "standalone"
      _ -> "standalone"
    end
  end

  defp derive_name_from_path(relative_path) do
    filename = Path.basename(relative_path, ".md")

    if filename == "SKILL" do
      relative_path |> Path.dirname() |> Path.basename()
    else
      filename
    end
  end

  defp find_md_files(dir) do
    Path.wildcard(Path.join(dir, "**/*.md"))
  end

  defp resolve_priv_skills_path do
    case :code.priv_dir(:optimal_system_agent) do
      {:error, _} ->
        app_dir = Application.app_dir(:optimal_system_agent)

        if app_dir do
          Path.join(app_dir, "priv/skills")
        else
          Path.join([File.cwd!(), "priv", "skills"])
        end

      priv_dir ->
        Path.join(to_string(priv_dir), "skills")
    end
  rescue
    _ ->
      Path.join([File.cwd!(), "priv", "skills"])
  end
end
