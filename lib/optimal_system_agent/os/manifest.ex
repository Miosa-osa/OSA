defmodule OptimalSystemAgent.OS.Manifest do
  @moduledoc """
  Parser and struct for `.osa-manifest.json` files.

  Templates (BusinessOS, ContentOS, custom) ship a `.osa-manifest.json`
  at their root to describe themselves to OSA. The manifest tells OSA:
  - What the template is and what stack it uses
  - Where its API lives and how to authenticate
  - Which modules are available (CRM, Projects, etc.)
  - What files to read for context
  - What skills to auto-generate

  ## Manifest Spec (v1)

      {
        "osa_manifest": 1,
        "name": "BusinessOS",
        "version": "1.0.0",
        "description": "All-in-one business management platform",
        "stack": {
          "backend": "go",
          "frontend": "svelte",
          "database": "postgresql"
        },
        "api": {
          "base_url": "http://localhost:8080",
          "docs": "docs/api-reference.md",
          "auth": "jwt"
        },
        "modules": [
          {
            "id": "crm",
            "name": "CRM",
            "description": "Contact and relationship management",
            "paths": ["backend/internal/modules/crm/"]
          }
        ],
        "context_sources": [
          "backend/internal/models/",
          "docs/"
        ],
        "skills": [
          {
            "name": "create_contact",
            "description": "Create a new CRM contact",
            "endpoint": "POST /api/v1/contacts"
          }
        ]
      }

  If no manifest exists, the scanner falls back to heuristic detection
  by reading project files (go.mod, package.json, mix.exs, etc.).
  """

  @enforce_keys [:name, :path]
  defstruct [
    :name,
    :path,
    :version,
    :description,
    :stack,
    :api,
    modules: [],
    context_sources: [],
    skills: [],
    manifest_version: 1,
    detected_at: nil
  ]

  @type stack :: %{
          optional(:backend) => String.t(),
          optional(:frontend) => String.t(),
          optional(:database) => String.t()
        }

  @type api_config :: %{
          optional(:base_url) => String.t(),
          optional(:docs) => String.t(),
          optional(:auth) => String.t()
        }

  @type os_module :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          paths: [String.t()]
        }

  @type skill_hint :: %{
          name: String.t(),
          description: String.t(),
          endpoint: String.t()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          path: String.t(),
          version: String.t() | nil,
          description: String.t() | nil,
          stack: stack() | nil,
          api: api_config() | nil,
          modules: [os_module()],
          context_sources: [String.t()],
          skills: [skill_hint()],
          manifest_version: pos_integer(),
          detected_at: DateTime.t() | nil
        }

  @doc """
  Parse a `.osa-manifest.json` file from disk.

  Returns `{:ok, manifest}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(manifest_path) do
    dir = Path.dirname(manifest_path)

    with {:ok, raw} <- File.read(manifest_path),
         {:ok, data} <- Jason.decode(raw) do
      {:ok, from_map(data, dir)}
    else
      {:error, %Jason.DecodeError{} = err} ->
        {:error, "Invalid JSON in #{manifest_path}: #{Exception.message(err)}"}

      {:error, reason} ->
        {:error, "Cannot read #{manifest_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Build a manifest struct from a decoded JSON map and the template's root path.
  """
  @spec from_map(map(), String.t()) :: t()
  def from_map(data, path) do
    %__MODULE__{
      name: data["name"] || Path.basename(path),
      path: path,
      version: data["version"],
      description: data["description"],
      stack: parse_stack(data["stack"]),
      api: parse_api(data["api"]),
      modules: parse_modules(data["modules"]),
      context_sources: data["context_sources"] || [],
      skills: parse_skills(data["skills"]),
      manifest_version: data["osa_manifest"] || 1,
      detected_at: DateTime.utc_now()
    }
  end

  @doc """
  Build a manifest from heuristic detection (no .osa-manifest.json).

  Reads project files to infer stack, name, and structure.
  """
  @spec from_heuristics(String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_heuristics(dir) do
    name = detect_name(dir)
    stack = detect_stack(dir)
    modules = detect_modules(dir, stack)

    if stack == %{} do
      {:error, "No recognizable project structure in #{dir}"}
    else
      {:ok,
       %__MODULE__{
         name: name,
         path: dir,
         version: nil,
         description: "Auto-detected #{name} (#{format_stack(stack)})",
         stack: stack,
         api: detect_api(dir, stack),
         modules: modules,
         context_sources: detect_context_sources(dir, stack),
         skills: [],
         manifest_version: 1,
         detected_at: DateTime.utc_now()
       }}
    end
  end

  @doc """
  Serialize a manifest to a JSON-encodable map for persistence.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = m) do
    %{
      "osa_manifest" => m.manifest_version,
      "name" => m.name,
      "path" => m.path,
      "version" => m.version,
      "description" => m.description,
      "stack" => m.stack,
      "api" => m.api,
      "modules" => Enum.map(m.modules, &module_to_map/1),
      "context_sources" => m.context_sources,
      "skills" => Enum.map(m.skills, &skill_to_map/1),
      "detected_at" => m.detected_at && DateTime.to_iso8601(m.detected_at)
    }
  end

  # --- Parsers ---

  defp parse_stack(nil), do: %{}

  defp parse_stack(map) when is_map(map) do
    map
    |> Enum.filter(fn {_k, v} -> is_binary(v) end)
    |> Map.new(fn {k, v} -> {k, v} end)
  end

  defp parse_stack(_), do: %{}

  defp parse_api(nil), do: nil

  defp parse_api(map) when is_map(map) do
    %{
      "base_url" => map["base_url"],
      "docs" => map["docs"],
      "auth" => map["auth"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_api(_), do: nil

  defp parse_modules(nil), do: []

  defp parse_modules(list) when is_list(list) do
    Enum.map(list, fn mod ->
      %{
        id: mod["id"] || mod["name"] || "unknown",
        name: mod["name"] || mod["id"] || "Unknown",
        description: mod["description"] || "",
        paths: mod["paths"] || []
      }
    end)
  end

  defp parse_modules(_), do: []

  defp parse_skills(nil), do: []

  defp parse_skills(list) when is_list(list) do
    Enum.map(list, fn skill ->
      %{
        name: skill["name"] || "unnamed",
        description: skill["description"] || "",
        endpoint: skill["endpoint"] || ""
      }
    end)
  end

  defp parse_skills(_), do: []

  defp module_to_map(%{id: id, name: name, description: desc, paths: paths}) do
    %{"id" => id, "name" => name, "description" => desc, "paths" => paths}
  end

  defp skill_to_map(%{name: name, description: desc, endpoint: ep}) do
    %{"name" => name, "description" => desc, "endpoint" => ep}
  end

  # --- Heuristic Detection ---

  defp detect_name(dir) do
    cond do
      File.exists?(Path.join(dir, "package.json")) ->
        case File.read(Path.join(dir, "package.json")) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, %{"name" => name}} when is_binary(name) -> name
              _ -> Path.basename(dir)
            end

          _ ->
            Path.basename(dir)
        end

      File.exists?(Path.join(dir, "go.mod")) ->
        case File.read(Path.join(dir, "go.mod")) do
          {:ok, content} ->
            content
            |> String.split(~r/\r?\n/, parts: 5)
            |> Enum.find(&String.starts_with?(&1, "module "))
            |> case do
              "module " <> mod_path ->
                mod_path |> String.split("/") |> List.last() |> String.trim()

              _ ->
                Path.basename(dir)
            end

          _ ->
            Path.basename(dir)
        end

      true ->
        Path.basename(dir)
    end
  end

  defp detect_stack(dir) do
    markers = [
      {"go.mod", "backend", "go"},
      {"mix.exs", "backend", "elixir"},
      {"Cargo.toml", "backend", "rust"},
      {"requirements.txt", "backend", "python"},
      {"pyproject.toml", "backend", "python"},
      {"package.json", "frontend", "node"}
    ]

    base =
      Enum.reduce(markers, %{}, fn {file, role, lang}, acc ->
        if File.exists?(Path.join(dir, file)) do
          Map.put(acc, role, lang)
        else
          acc
        end
      end)

    # Refine frontend detection
    base = refine_frontend(base, dir)

    # Detect database
    detect_database(base, dir)
  end

  defp refine_frontend(stack, dir) do
    cond do
      File.exists?(Path.join(dir, "svelte.config.js")) or
          File.exists?(Path.join(dir, "svelte.config.ts")) ->
        Map.put(stack, "frontend", "svelte")

      File.exists?(Path.join(dir, "next.config.js")) or
        File.exists?(Path.join(dir, "next.config.ts")) or
          File.exists?(Path.join(dir, "next.config.mjs")) ->
        Map.put(stack, "frontend", "react-next")

      File.exists?(Path.join(dir, "vite.config.ts")) or
          File.exists?(Path.join(dir, "vite.config.js")) ->
        Map.put(stack, "frontend", "vite")

      # Check subdirectories for monorepos
      File.exists?(Path.join([dir, "frontend", "svelte.config.js"])) or
          File.exists?(Path.join([dir, "frontend", "svelte.config.ts"])) ->
        Map.put(stack, "frontend", "svelte")

      File.exists?(Path.join([dir, "frontend", "next.config.js"])) or
          File.exists?(Path.join([dir, "frontend", "next.config.ts"])) ->
        Map.put(stack, "frontend", "react-next")

      true ->
        stack
    end
  end

  defp detect_database(stack, dir) do
    cond do
      has_file_containing?(dir, "docker-compose.yml", "postgres") ->
        Map.put(stack, "database", "postgresql")

      has_file_containing?(dir, "docker-compose.yml", "mysql") ->
        Map.put(stack, "database", "mysql")

      has_file_containing?(dir, "docker-compose.yml", "mongo") ->
        Map.put(stack, "database", "mongodb")

      File.exists?(Path.join(dir, "prisma")) ->
        Map.put(stack, "database", "prisma")

      true ->
        stack
    end
  end

  defp has_file_containing?(dir, filename, needle) do
    path = Path.join(dir, filename)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.downcase()
        |> String.contains?(String.downcase(needle))

      _ ->
        false
    end
  end

  defp detect_modules(dir, stack) do
    cond do
      stack["backend"] == "go" ->
        scan_go_modules(dir)

      stack["frontend"] == "svelte" ->
        scan_svelte_routes(dir)

      true ->
        []
    end
  end

  defp scan_go_modules(dir) do
    # Check backend/internal/modules/ (BusinessOS pattern)
    modules_dir =
      [
        Path.join([dir, "backend", "internal", "modules"]),
        Path.join([dir, "internal", "modules"]),
        Path.join([dir, "pkg", "modules"])
      ]
      |> Enum.find(&File.dir?/1)

    case modules_dir do
      nil ->
        []

      found ->
        found
        |> list_dir()
        |> Enum.filter(&File.dir?(Path.join(found, &1)))
        |> Enum.map(fn mod_name ->
          %{
            id: mod_name,
            name: mod_name |> String.replace("_", " ") |> String.capitalize(),
            description: "Auto-detected Go module",
            paths: [Path.relative_to(Path.join(found, mod_name), dir)]
          }
        end)
    end
  end

  defp scan_svelte_routes(dir) do
    routes_dir =
      [
        Path.join([dir, "frontend", "src", "routes"]),
        Path.join([dir, "src", "routes"])
      ]
      |> Enum.find(&File.dir?/1)

    case routes_dir do
      nil ->
        []

      found ->
        found
        |> list_dir()
        |> Enum.filter(fn entry ->
          full = Path.join(found, entry)
          File.dir?(full) and not String.starts_with?(entry, "(") and entry != "api"
        end)
        |> Enum.map(fn route ->
          %{
            id: route,
            name: route |> String.replace("-", " ") |> String.capitalize(),
            description: "Auto-detected route module",
            paths: [Path.relative_to(Path.join(found, route), dir)]
          }
        end)
    end
  end

  defp detect_api(dir, stack) do
    cond do
      stack["backend"] == "go" ->
        # Look for common Go API patterns
        api_docs =
          ["docs/api-reference.md", "docs/http-api.md", "docs/API.md", "api/openapi.yaml"]
          |> Enum.find(fn doc -> File.exists?(Path.join(dir, doc)) end)

        %{"base_url" => "http://localhost:8080", "auth" => "jwt"}
        |> then(fn m -> if api_docs, do: Map.put(m, "docs", api_docs), else: m end)

      stack["backend"] == "elixir" ->
        %{"base_url" => "http://localhost:4000"}

      stack["backend"] == "node" ->
        %{"base_url" => "http://localhost:3000"}

      true ->
        nil
    end
  end

  defp detect_context_sources(dir, stack) do
    candidates =
      [
        {"backend/internal/models", stack["backend"] == "go"},
        {"backend/internal/modules", stack["backend"] == "go"},
        {"frontend/src/lib/types", stack["frontend"] == "svelte"},
        {"frontend/src/lib/stores", stack["frontend"] == "svelte"},
        {"lib", stack["backend"] == "elixir"},
        {"src", stack["frontend"] in ["react-next", "vite"]},
        {"docs", true},
        {"README.md", true}
      ]

    candidates
    |> Enum.filter(fn {path, cond_val} ->
      cond_val and File.exists?(Path.join(dir, path))
    end)
    |> Enum.map(fn {path, _} -> path end)
  end

  defp format_stack(stack) do
    stack
    |> Enum.map(fn {role, lang} -> "#{role}=#{lang}" end)
    |> Enum.join(", ")
  end

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end
end
