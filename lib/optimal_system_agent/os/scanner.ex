defmodule OptimalSystemAgent.OS.Scanner do
  @moduledoc """
  Filesystem scanner for OS templates.

  Scans configured directories for templates that OSA can connect to.
  A template is identified by:
  1. A `.osa-manifest.json` file at the project root (preferred)
  2. Heuristic detection via project files (go.mod, package.json, etc.)

  ## Scan Strategy

  The scanner checks these locations in order:
  1. Paths listed in `~/.osa/config.json` under `"os.scan_paths"`
  2. `~/.osa/templates/` (dedicated template directory)
  3. Home directory project folders (~/Desktop, ~/Projects, ~/Developer, ~/Code)
  4. User-specified path via `scan/1`

  The scanner is stateless — it performs a scan and returns results.
  The `OS.Registry` GenServer calls the scanner and manages state.
  """

  alias OptimalSystemAgent.OS.Manifest
  require Logger

  @config_dir Application.compile_env(:optimal_system_agent, :config_dir, "~/.osa")

  @default_scan_dirs [
    "~/.osa/templates",
    "~/Desktop",
    "~/Projects",
    "~/Developer",
    "~/Code",
    "~/dev",
    "~/src",
  ]

  @manifest_filename ".osa-manifest.json"

  # Skip directories that are never templates
  @skip_dirs MapSet.new([
    "node_modules", "_build", "deps", ".git", ".svn", ".hg",
    "vendor", "target", "__pycache__", ".next", ".svelte-kit",
    "dist", "build", ".cache", "tmp", ".tmp", "coverage",
    "venv", ".venv", ".env", "env",
  ])

  # --- Public API ---

  @doc """
  Scan all configured directories for OS templates.

  Returns a list of `Manifest` structs for each discovered template.
  """
  @spec scan_all() :: [Manifest.t()]
  def scan_all do
    dirs = scan_directories()

    Logger.info("OS Scanner: scanning #{length(dirs)} directories")

    dirs
    |> Enum.flat_map(&scan_directory/1)
    |> Enum.uniq_by(fn m -> m.path end)
  end

  @doc """
  Scan a specific directory for an OS template.

  Checks for `.osa-manifest.json` first, then falls back to heuristics.
  Returns `{:ok, manifest}` or `{:error, reason}`.
  """
  @spec scan(String.t()) :: {:ok, Manifest.t()} | {:error, String.t()}
  def scan(path) do
    dir = Path.expand(path)

    cond do
      not File.dir?(dir) ->
        {:error, "Not a directory: #{dir}"}

      has_manifest?(dir) ->
        Manifest.parse(manifest_path(dir))

      is_project?(dir) ->
        Manifest.from_heuristics(dir)

      true ->
        {:error, "No recognizable project in #{dir}"}
    end
  end

  @doc """
  Generate a `.osa-manifest.json` file for a template.

  If the directory has no manifest, scans heuristically and writes
  the result as a manifest file the template can ship.
  """
  @spec generate_manifest(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def generate_manifest(path) do
    dir = Path.expand(path)

    if has_manifest?(dir) do
      {:error, "Manifest already exists at #{manifest_path(dir)}"}
    else
      case Manifest.from_heuristics(dir) do
        {:ok, manifest} ->
          out_path = manifest_path(dir)
          json = manifest |> Manifest.to_map() |> Map.drop(["detected_at"]) |> Jason.encode!(pretty: true)

          case File.write(out_path, json) do
            :ok -> {:ok, out_path}
            {:error, reason} -> {:error, "Failed to write manifest: #{:file.format_error(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- Scan Logic ---

  defp scan_directories do
    configured = load_configured_paths()
    defaults = Enum.map(@default_scan_dirs, &Path.expand/1)

    (configured ++ defaults)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  defp load_configured_paths do
    config_path = Path.expand(Path.join(@config_dir, "config.json"))

    with {:ok, raw} <- File.read(config_path),
         {:ok, config} <- Jason.decode(raw) do
      config
      |> get_in(["os", "scan_paths"])
      |> case do
        paths when is_list(paths) -> Enum.map(paths, &Path.expand/1)
        _ -> []
      end
    else
      _ -> []
    end
  end

  defp scan_directory(dir) do
    # Check if this directory itself is a template
    case scan(dir) do
      {:ok, manifest} ->
        [manifest]

      {:error, _} ->
        # Not a template — scan one level deep for child templates
        scan_children(dir)
    end
  end

  defp scan_children(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in @skip_dirs))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.reduce([], fn child_dir, acc ->
          case scan(child_dir) do
            {:ok, manifest} -> [manifest | acc]
            {:error, _} -> acc
          end
        end)

      {:error, _} ->
        []
    end
  end

  # --- Detection Helpers ---

  defp has_manifest?(dir), do: File.exists?(manifest_path(dir))

  defp manifest_path(dir), do: Path.join(dir, @manifest_filename)

  @project_markers [
    "go.mod", "mix.exs", "Cargo.toml", "package.json",
    "pyproject.toml", "requirements.txt", "pom.xml",
    "build.gradle", "CMakeLists.txt", "Makefile",
  ]

  defp is_project?(dir) do
    Enum.any?(@project_markers, fn marker ->
      File.exists?(Path.join(dir, marker))
    end)
  end
end
