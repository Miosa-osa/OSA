defmodule OptimalSystemAgent.Tools.Builtins.SkillManager do
  @moduledoc """
  Skill lifecycle management tool — list, search, create, enable, disable, delete, reload.

  Superset of `create_skill`. Provides the LLM with full CRUD over the skill
  system so it can manage its own capabilities. All disk I/O the model can't
  do alone is handled here; the decision of *when* to create skills is left to
  model intelligence via SYSTEM.md instructions.
  """
  @behaviour MiosaTools.Behaviour

  require Logger

  alias OptimalSystemAgent.Tools.Registry
  alias OptimalSystemAgent.Tools.Registry.SkillLoader

  defp skills_dir, do: Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")

  # Deferred: absent from the default toolbox, discovered mid-turn via
  # `tool_search`. Reason: managing skills is a setup action, not something a turn does.
  #
  # Every schema in the default set is re-sent on EVERY request. Measured
  # across 15 SWE-bench Pro transcripts, this tool was called zero times while
  # costing its schema on all 863 turns.
  def should_defer?, do: true

  @impl true
  def name, do: "skill_manager"

  @impl true
  def description do
    "Manage custom skills: list, search, create, enable, disable, delete, or reload. " <>
      "Use this to extend your capabilities by creating reusable skills from repeating patterns."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["list", "search", "create", "enable", "disable", "delete", "reload"],
          "description" => "Action to perform"
        },
        "name" => %{
          "type" => "string",
          "description" => "Skill name (for create/enable/disable/delete)"
        },
        "query" => %{
          "type" => "string",
          "description" => "Search query (for search action)"
        },
        "description" => %{
          "type" => "string",
          "description" => "Skill description (for create)"
        },
        "instructions" => %{
          "type" => "string",
          "description" => "Skill instructions/prompt (for create)"
        },
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Tools this skill needs (for create)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def available?, do: true

  # `delete` recursively removes a directory tree (`File.rm_rf!`). That is not
  # recoverable and must never sit on the auto-approvable side of the
  # taxonomy, whatever the other actions do — `safety/0` has no per-action
  # granularity, so the tool is classified by its most dangerous action.
  @impl true
  def safety, do: :write_destructive

  @impl true
  def execute(%{"action" => "list"}) do
    # List what the LOADER sees, not one flat directory: a nested or
    # project-scoped skill is just as real to the model, and its enabled state
    # comes from the canonical marker check.
    custom_skills =
      SkillLoader.load_skills()
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {skill_name, entry} ->
        status = if SkillLoader.disabled?(entry), do: "disabled", else: "active"
        "  #{String.pad_trailing(skill_name, 24)} [#{status}] (#{entry.scope})"
      end)

    builtin_tools = Registry.list_tools_direct()

    builtin_section =
      Enum.map_join(builtin_tools, "\n", fn tool ->
        "  #{String.pad_trailing(tool.name, 24)} [built-in]"
      end)

    custom_section =
      if custom_skills == [] do
        "  (none)"
      else
        Enum.join(custom_skills, "\n")
      end

    {:ok,
     "Built-in tools (#{length(builtin_tools)}):\n#{builtin_section}\n\n" <>
       "Custom skills (#{length(custom_skills)}):\n#{custom_section}"}
  end

  def execute(%{"action" => "search", "query" => query}) when is_binary(query) do
    results = Registry.search(query)

    if results == [] do
      {:ok, "No skills match '#{query}'."}
    else
      formatted =
        Enum.map_join(results, "\n", fn {name, desc, score} ->
          "  #{String.pad_trailing(name, 20)} #{Float.round(score, 2)} — #{String.slice(desc, 0, 60)}"
        end)

      {:ok, "Matching skills (#{length(results)}):\n#{formatted}"}
    end
  end

  def execute(%{"action" => "search"}) do
    {:error, "search action requires a 'query' parameter"}
  end

  def execute(
        %{
          "action" => "create",
          "name" => name,
          "description" => desc,
          "instructions" => instructions
        } = params
      ) do
    tools = params["tools"] || []

    case resolve_skill_dir(name) do
      {:ok, _dir} -> do_create_skill(name, desc, instructions, tools)
      {:error, _} = err -> err
    end
  end

  def execute(%{"action" => "create"}) do
    {:error, "create action requires: name, description, instructions"}
  end

  def execute(%{"action" => "enable", "name" => name}) do
    with {:ok, skill_dir} <- resolve_installed_skill_dir(name) do
      marker = Path.join(skill_dir, ".disabled")

      if File.exists?(marker) do
        File.rm(marker)
        Registry.reload_skills()
        {:ok, "Skill '#{name}' enabled and registry reloaded."}
      else
        {:ok, "Skill '#{name}' is already enabled."}
      end
    end
  end

  def execute(%{"action" => "enable"}) do
    {:error, "enable action requires a 'name' parameter"}
  end

  def execute(%{"action" => "disable", "name" => name}) do
    with {:ok, skill_dir} <- resolve_installed_skill_dir(name) do
      marker = Path.join(skill_dir, ".disabled")

      case File.write(marker, "disabled at #{DateTime.utc_now() |> DateTime.to_iso8601()}") do
        :ok ->
          Registry.reload_skills()
          {:ok, "Skill '#{name}' disabled (marker written to #{marker})."}

        {:error, reason} ->
          {:error,
           "Could not disable '#{name}': cannot write #{marker} (#{inspect(reason)}). " <>
             "Bundled skills live in a read-only install directory."}
      end
    end
  end

  def execute(%{"action" => "disable"}) do
    {:error, "disable action requires a 'name' parameter"}
  end

  def execute(%{"action" => "delete", "name" => name}) do
    with {:ok, skill_dir} <- resolve_skill_dir(name) do
      if File.dir?(skill_dir) do
        File.rm_rf!(skill_dir)
        Registry.reload_skills()
        {:ok, "Skill '#{name}' deleted from #{skills_dir()}/#{name}/."}
      else
        {:error, "Skill '#{name}' not found."}
      end
    end
  end

  def execute(%{"action" => "delete"}) do
    {:error, "delete action requires a 'name' parameter"}
  end

  def execute(%{"action" => "reload"}) do
    Registry.reload_skills()
    tools = Registry.list_tools_direct()
    {:ok, "Skills reloaded. #{length(tools)} tools now available."}
  end

  def execute(%{"action" => action}) do
    {:error,
     "Unknown action: #{action}. Valid: list, search, create, enable, disable, delete, reload"}
  end

  def execute(_) do
    {:error, "Missing required parameter: action"}
  end

  # ── Private ─────────────────────────────────────────────────────

  # `name` arrives straight from an LLM tool call as a free-form string, and
  # every mutating action turns it into a filesystem path. `Path.join/2` does
  # NOT normalize `..`, so `name: ".."` used to expand to the skills dir's
  # PARENT — `File.rm_rf!("~/.osa")`, taking sessions, transcripts, memory,
  # credentials and config with it. `"."` and `""` wiped the whole skills tree.
  #
  # Two independent checks, deliberately not one:
  #
  #   1. The kebab-case regex rejects every traversal spelling up front
  #      (`..`, `.`, `""`, absolute paths, separators, NUL bytes).
  #   2. Containment is then PROVEN on the expanded path — the regex is a
  #      syntactic filter, not proof of where a path lands, and only the
  #      expansion can show that. The target must be strictly inside the
  #      skills dir and must not BE the skills dir.
  @name_re ~r/^[a-z][a-z0-9_-]*$/

  @spec resolve_skill_dir(term()) :: {:ok, Path.t()} | {:error, String.t()}
  defp resolve_skill_dir(name) when is_binary(name) do
    if Regex.match?(@name_re, name) do
      root = Path.expand(skills_dir())
      dir = Path.expand(Path.join(root, name))

      if dir != root and String.starts_with?(dir, root <> "/") do
        {:ok, dir}
      else
        {:error, "Skill name escapes the skills directory: #{inspect(name)}"}
      end
    else
      {:error,
       "Skill name must be kebab-case (lowercase, numbers, hyphens, underscores). Got: #{inspect(name)}"}
    end
  end

  defp resolve_skill_dir(name),
    do: {:error, "Skill name must be a string. Got: #{inspect(name)}"}

  # enable/disable must reach the skill the LOADER actually surfaced, wherever
  # it lives — nested under a category directory, named differently from its
  # directory, or in a project/bundled scope. The old flat
  # `<skills_dir>/<name>/` guess meant those skills could not be disabled at
  # all while remaining fully visible to the model.
  #
  # Containment is still PROVEN, exactly as `resolve_skill_dir/1` does it: the
  # resolved directory must sit strictly inside one of the loader's own
  # discovery roots. The name is looked up, never joined into a path, so a
  # traversal spelling simply fails to match a loaded skill.
  @spec resolve_installed_skill_dir(term()) :: {:ok, Path.t()} | {:error, String.t()}
  defp resolve_installed_skill_dir(name) when is_binary(name) do
    case Map.get(SkillLoader.load_skills(), name) do
      %{path: path} when is_binary(path) ->
        dir = Path.expand(Path.dirname(path))

        if SkillLoader.within_roots?(dir) and
             dir not in Enum.map(SkillLoader.roots(), &Path.expand/1) do
          {:ok, dir}
        else
          {:error,
           "Skill '#{name}' resolves outside every skills directory — refusing to touch it."}
        end

      _ ->
        {:error, "Skill '#{name}' not found. Use action \"list\" to see loaded skills."}
    end
  end

  defp resolve_installed_skill_dir(name),
    do: {:error, "Skill name must be a string. Got: #{inspect(name)}"}

  defp do_create_skill(name, desc, instructions, tools) do
    dir = Path.join(Path.expand(skills_dir()), name)
    file = Path.join(dir, "SKILL.md")

    if File.exists?(file) do
      {:error,
       "Skill '#{name}' already exists at #{file}. Delete it first or use a different name."}
    else
      File.mkdir_p!(dir)

      tools_yaml =
        if tools == [] do
          ""
        else
          "tools:\n" <> Enum.map_join(tools, "\n", fn t -> "  - #{t}" end) <> "\n"
        end

      # `source:` is the provenance marker Skills.Curator classifies on, and
      # the same field SkillGenerator uses (`auto:<pattern_id>`). Without it a
      # tool-created skill is indistinguishable from a hand-written one.
      content = """
      ---
      name: #{name}
      description: #{desc}
      source: skill_manager
      #{tools_yaml}---

      #{instructions}
      """

      File.write!(file, content)

      Logger.info("[SkillManager] Created skill: #{name} at #{file}")

      Registry.reload_skills()
      {:ok, "Skill '#{name}' created at #{file} and registered."}
    end
  rescue
    e ->
      Logger.error("[SkillManager] Create failed: #{Exception.message(e)}")
      {:error, "Failed to create skill: #{Exception.message(e)}"}
  end
end
