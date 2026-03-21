defmodule OptimalSystemAgent.Channels.HTTP.API.CanopyRoutes do
  @moduledoc """
  Canopy workspace routes for the OSA HTTP API.

  Forwarded prefix: /canopy

  Canopy is the filesystem-based workspace protocol for AI agent collaboration.
  Each workspace is a directory containing a `.canopy/` folder with agent
  definitions, skills, reference knowledge, and governance documents.

  Workspace registry: ~/.osa/workspaces.json

  Effective routes:
    GET    /canopy                → List all tracked workspaces
    POST   /canopy                → Create and register a new workspace
    GET    /canopy/:id            → Get workspace details + file contents
    PATCH  /canopy/:id            → Update workspace metadata (name, description)
    POST   /canopy/:id/activate   → Set workspace as active (deactivates all others)
    GET    /canopy/:id/agents     → List agents from .canopy/agents/*.md
    GET    /canopy/:id/skills     → List skills from .canopy/skills/*.md
    GET    /canopy/:id/config     → Read SYSTEM.md and COMPANY.md contents
    DELETE /canopy/:id            → Remove workspace from tracking (filesystem untouched)
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug :match
  plug :dispatch

  # ── GET / — list all workspaces ────────────────────────────────────────────

  get "/" do
    workspaces =
      try do
        read_workspaces()
        |> Enum.map(&enrich_workspace/1)
      rescue
        e ->
          Logger.warning("[CanopyRoutes] Failed to list workspaces: #{Exception.message(e)}")
          []
      end

    json(conn, 200, %{workspaces: workspaces, count: length(workspaces)})
  end

  # ── POST / — create a new workspace ───────────────────────────────────────

  post "/" do
    params = conn.body_params

    name = params["name"]
    description = params["description"] || ""
    path = params["path"]

    cond do
      not (is_binary(name) and name != "") ->
        json_error(conn, 400, "invalid_request", "Missing required field: name")

      not (is_binary(path) and path != "") ->
        json_error(conn, 400, "invalid_request", "Missing required field: path")

      not File.dir?(path) ->
        json_error(conn, 400, "invalid_path", "Path does not exist or is not a directory")

      true ->
        try do
          workspace = create_workspace(name, description, path)
          json(conn, 201, workspace)
        rescue
          e ->
            Logger.error("[CanopyRoutes] Workspace creation failed: #{Exception.message(e)}")
            json_error(conn, 500, "create_failed", "Failed to create workspace")
        end
    end
  end

  # ── GET /:id — workspace detail ────────────────────────────────────────────

  get "/:id" do
    id = conn.params["id"]

    case find_workspace(read_workspaces(), id) do
      nil ->
        json_error(conn, 404, "not_found", "Workspace #{id} not found")

      workspace ->
        enriched = enrich_workspace(workspace)

        detail =
          Map.merge(enriched, %{
            system_md: read_canopy_file(workspace["path"], "SYSTEM.md"),
            company_md: read_canopy_file(workspace["path"], "COMPANY.md")
          })

        json(conn, 200, detail)
    end
  end

  # ── PATCH /:id — update workspace metadata ─────────────────────────────────

  patch "/:id" do
    id = conn.params["id"]
    params = conn.body_params

    workspaces = read_workspaces()

    case find_workspace(workspaces, id) do
      nil ->
        json_error(conn, 404, "not_found", "Workspace #{id} not found")

      _workspace ->
        try do
          allowed = Map.take(params, ["name", "description"])

          if map_size(allowed) == 0 do
            json_error(conn, 400, "invalid_request", "No updatable fields provided (name, description)")
          else
            updated_workspaces =
              Enum.map(workspaces, fn ws ->
                if ws["id"] == id do
                  Map.merge(ws, allowed)
                  |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
                else
                  ws
                end
              end)

            write_workspaces(updated_workspaces)

            updated = find_workspace(updated_workspaces, id)
            json(conn, 200, enrich_workspace(updated))
          end
        rescue
          e ->
            Logger.error("[CanopyRoutes] PATCH #{id} failed: #{Exception.message(e)}")
            json_error(conn, 500, "update_failed", "Failed to update workspace")
        end
    end
  end

  # ── POST /:id/activate — set workspace as active ───────────────────────────

  post "/:id/activate" do
    id = conn.params["id"]
    workspaces = read_workspaces()

    case find_workspace(workspaces, id) do
      nil ->
        json_error(conn, 404, "not_found", "Workspace #{id} not found")

      _workspace ->
        try do
          updated_workspaces =
            Enum.map(workspaces, fn ws ->
              Map.put(ws, "active", ws["id"] == id)
            end)

          write_workspaces(updated_workspaces)

          json(conn, 200, %{status: "activated", workspace_id: id})
        rescue
          e ->
            Logger.error("[CanopyRoutes] activate #{id} failed: #{Exception.message(e)}")
            json_error(conn, 500, "activate_failed", "Failed to activate workspace")
        end
    end
  end

  # ── GET /:id/agents — list agents from .canopy/agents/ ────────────────────

  get "/:id/agents" do
    id = conn.params["id"]

    case find_workspace(read_workspaces(), id) do
      nil ->
        json_error(conn, 404, "not_found", "Workspace #{id} not found")

      workspace ->
        agents = scan_canopy_dir(workspace["path"], "agents")
        json(conn, 200, %{agents: agents, count: length(agents)})
    end
  end

  # ── GET /:id/skills — list skills from .canopy/skills/ ────────────────────

  get "/:id/skills" do
    id = conn.params["id"]

    case find_workspace(read_workspaces(), id) do
      nil ->
        json_error(conn, 404, "not_found", "Workspace #{id} not found")

      workspace ->
        skills = scan_canopy_dir(workspace["path"], "skills")
        json(conn, 200, %{skills: skills, count: length(skills)})
    end
  end

  # ── GET /:id/config — read SYSTEM.md and COMPANY.md ───────────────────────

  get "/:id/config" do
    id = conn.params["id"]

    case find_workspace(read_workspaces(), id) do
      nil ->
        json_error(conn, 404, "not_found", "Workspace #{id} not found")

      workspace ->
        path = workspace["path"]
        system_md = read_canopy_file(path, "SYSTEM.md")
        company_md = read_canopy_file(path, "COMPANY.md")

        json(conn, 200, %{
          system: system_md,
          company: company_md,
          has_system: is_binary(system_md),
          has_company: is_binary(company_md)
        })
    end
  end

  # ── DELETE /:id — remove from tracking (filesystem untouched) ─────────────

  delete "/:id" do
    id = conn.params["id"]
    workspaces = read_workspaces()

    case find_workspace(workspaces, id) do
      nil ->
        json_error(conn, 404, "not_found", "Workspace #{id} not found")

      _workspace ->
        try do
          remaining = Enum.reject(workspaces, &(&1["id"] == id))
          write_workspaces(remaining)

          json(conn, 200, %{status: "removed", workspace_id: id})
        rescue
          e ->
            Logger.error("[CanopyRoutes] DELETE #{id} failed: #{Exception.message(e)}")
            json_error(conn, 500, "delete_failed", "Failed to remove workspace from tracking")
        end
    end
  end

  # ── Catch-all ──────────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Workspace endpoint not found")
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  # Path to the workspace registry JSON file.
  defp workspaces_path do
    Path.expand("~/.osa/workspaces.json")
  end

  # Read and parse all workspaces. Returns [] on any failure.
  defp read_workspaces do
    path = workspaces_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content),
         true <- is_list(parsed) do
      parsed
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # Encode workspaces as pretty JSON and write to disk.
  defp write_workspaces(workspaces) do
    path = workspaces_path()
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(workspaces, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)

      {:error, reason} ->
        Logger.warning("[CanopyRoutes] Failed to encode workspaces: #{inspect(reason)}")
    end
  end

  # Find a workspace map by ID. Returns nil when not found.
  defp find_workspace(workspaces, id) do
    Enum.find(workspaces, fn ws -> ws["id"] == id end)
  end

  # Enrich a raw workspace map with filesystem-derived fields.
  defp enrich_workspace(workspace) do
    path = workspace["path"]
    has_canopy = File.dir?(Path.join(path, ".canopy"))

    agent_count =
      try do
        Path.wildcard(Path.join([path, ".canopy", "agents", "*.md"])) |> length()
      rescue
        _ -> 0
      end

    skill_count =
      try do
        Path.wildcard(Path.join([path, ".canopy", "skills", "*.md"])) |> length()
      rescue
        _ -> 0
      end

    workspace
    |> Map.put("has_canopy", has_canopy)
    |> Map.put("agent_count", agent_count)
    |> Map.put("skill_count", skill_count)
  end

  # Parse YAML frontmatter from a markdown file. Returns a map of string key→value.
  # Only the first frontmatter block (between opening and closing ---) is parsed.
  # Lists in YAML (e.g. capabilities: [...]) are returned as-is strings unless they
  # use inline bracket notation, in which case they are split into a list.
  defp parse_frontmatter(content) when is_binary(content) do
    case String.split(content, "---", parts: 3) do
      [_, frontmatter, _body] ->
        frontmatter
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/^(\w[\w_-]*):\s*(.+)$/, String.trim(line)) do
            [_, key, value] ->
              Map.put(acc, key, parse_yaml_value(String.trim(value)))

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp parse_frontmatter(_), do: %{}

  # Parse a YAML scalar value: inline lists, quoted strings, bare strings.
  defp parse_yaml_value("[" <> rest) do
    # Inline YAML list: [item1, item2, ...]
    inner = rest |> String.trim_trailing("]")

    inner
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&strip_quotes/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_yaml_value(value) do
    strip_quotes(value)
  end

  defp strip_quotes("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp strip_quotes("'" <> rest), do: String.trim_trailing(rest, "'")
  defp strip_quotes(value), do: value

  # Scan a .canopy sub-directory and parse frontmatter from each .md file.
  defp scan_canopy_dir(workspace_path, subdir) do
    pattern = Path.join([workspace_path, ".canopy", subdir, "*.md"])

    try do
      Path.wildcard(pattern)
      |> Enum.map(fn file_path ->
        filename = Path.basename(file_path)

        frontmatter =
          case File.read(file_path) do
            {:ok, content} -> parse_frontmatter(content)
            {:error, _} -> %{}
          end

        Map.put(frontmatter, "file", filename)
      end)
    rescue
      e ->
        Logger.warning("[CanopyRoutes] Failed to scan #{subdir}: #{Exception.message(e)}")
        []
    end
  end

  # Read a file from the .canopy directory. Returns the string content or nil.
  defp read_canopy_file(workspace_path, filename) do
    file_path = Path.join([workspace_path, ".canopy", filename])

    case File.read(file_path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  # Generate a workspace ID: "ws_" followed by 11 URL-safe base64 characters.
  defp generate_id do
    "ws_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  # Create the .canopy directory scaffold and register the workspace.
  defp create_workspace(name, description, path) do
    id = generate_id()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Build .canopy scaffold directories
    File.mkdir_p!(Path.join([path, ".canopy", "agents"]))
    File.mkdir_p!(Path.join([path, ".canopy", "skills"]))
    File.mkdir_p!(Path.join([path, ".canopy", "reference"]))

    desc_text =
      if description != "",
        do: description,
        else: "A Canopy workspace for AI agent collaboration."

    # Write SYSTEM.md
    system_md = """
    ---
    name: #{name}
    version: "1.0"
    created: #{now}
    ---

    # #{name}

    #{desc_text}

    ## Mission

    Define your workspace mission here.

    ## Boot Sequence

    1. Load agent definitions from `.canopy/agents/`
    2. Load skills from `.canopy/skills/`
    3. Initialize with reference knowledge
    """

    File.write!(Path.join([path, ".canopy", "SYSTEM.md"]), system_md)

    # Write COMPANY.md
    company_md = """
    ---
    name: #{name}
    ---

    # Organization

    ## Team Structure

    Define your agent hierarchy here.

    ## Budget

    Define token budgets per agent.

    ## Governance

    Define approval workflows and policies.
    """

    File.write!(Path.join([path, ".canopy", "COMPANY.md"]), company_md)

    # Register the workspace
    workspace = %{
      "id" => id,
      "name" => name,
      "description" => description,
      "path" => path,
      "active" => false,
      "created_at" => now,
      "updated_at" => now
    }

    existing = read_workspaces()
    write_workspaces(existing ++ [workspace])

    enrich_workspace(workspace)
  end
end
