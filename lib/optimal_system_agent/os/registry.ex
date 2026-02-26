defmodule OptimalSystemAgent.OS.Registry do
  @moduledoc """
  Registry of connected OS templates.

  Manages the lifecycle of OS template connections:
  1. Scan the filesystem for templates (via `OS.Scanner`)
  2. Connect templates (persist to `~/.osa/os/{name}.json`)
  3. Provide template context to the agent prompt
  4. Disconnect templates

  Connected OS templates inject context into the agent's system prompt,
  giving it awareness of the template's structure, modules, and API.

  ## Configuration

  Templates can be auto-discovered or manually connected:

      # Auto-scan (runs at boot)
      OS.Registry.scan()

      # Manual connect
      OS.Registry.connect("/path/to/BusinessOS")

      # List connected
      OS.Registry.list()

      # Disconnect
      OS.Registry.disconnect("BusinessOS")

  Connected templates are persisted to `~/.osa/os/` so they survive
  restarts. The agent prompt includes context for all connected templates.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.OS.{Manifest, Scanner}

  @config_dir Application.compile_env(:optimal_system_agent, :config_dir, "~/.osa")

  @type state :: %__MODULE__{
          connected: %{String.t() => Manifest.t()},
          discovered: %{String.t() => Manifest.t()}
        }

  defstruct connected: %{}, discovered: %{}

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "List all connected OS templates."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get a connected OS template by name. Returns `{:ok, manifest}` or `:error`."
  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc "Connect an OS template by path. Scans, persists, and activates."
  def connect(path) do
    GenServer.call(__MODULE__, {:connect, path}, 30_000)
  end

  @doc "Disconnect an OS template by name."
  def disconnect(name) do
    GenServer.call(__MODULE__, {:disconnect, name})
  end

  @doc "Scan filesystem for discoverable templates (does not auto-connect)."
  def scan do
    GenServer.call(__MODULE__, :scan, 30_000)
  end

  @doc "Get prompt addendums for all connected OS templates."
  def prompt_addendums do
    GenServer.call(__MODULE__, :prompt_addendums)
  end

  @doc "List discovered (but not yet connected) templates."
  def discovered do
    GenServer.call(__MODULE__, :discovered)
  end

  # --- Server Callbacks ---

  @impl true
  def init(:ok) do
    ensure_os_dir()
    connected = load_persisted()

    Logger.info("OS Registry: #{map_size(connected)} connected templates loaded")

    # Warn about paths that no longer exist but keep them
    # (may be temporarily unavailable — network mount, USB, etc.)
    validate_paths(connected)

    {:ok, %__MODULE__{connected: connected, discovered: %{}}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    templates =
      state.connected
      |> Enum.map(fn {name, manifest} ->
        %{
          name: name,
          path: manifest.path,
          version: manifest.version,
          stack: manifest.stack,
          modules: length(manifest.modules),
          description: manifest.description
        }
      end)

    {:reply, templates, state}
  end

  def handle_call({:get, name}, _from, state) do
    result =
      case Map.fetch(state.connected, name) do
        {:ok, manifest} -> {:ok, manifest}
        :error -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:connect, path}, _from, state) do
    expanded = Path.expand(path)

    case Scanner.scan(expanded) do
      {:ok, manifest} ->
        name = manifest.name
        persist(manifest)
        connected = Map.put(state.connected, name, manifest)
        Logger.info("OS Registry: connected '#{name}' at #{expanded}")
        {:reply, {:ok, manifest}, %{state | connected: connected}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disconnect, name}, _from, state) do
    case Map.pop(state.connected, name) do
      {nil, _} ->
        {:reply, {:error, "Not connected: #{name}"}, state}

      {_manifest, connected} ->
        remove_persisted(name)
        Logger.info("OS Registry: disconnected '#{name}'")
        {:reply, :ok, %{state | connected: connected}}
    end
  end

  def handle_call(:scan, _from, state) do
    templates = Scanner.scan_all()
    connected_paths = MapSet.new(state.connected, fn {_name, m} -> m.path end)

    # Only include templates not already connected, warn on name collision
    discovered =
      templates
      |> Enum.reject(fn m -> m.path in connected_paths end)
      |> Enum.reduce(%{}, fn m, acc ->
        if Map.has_key?(acc, m.name) do
          Logger.warning(
            "OS Registry: name collision '#{m.name}' — #{m.path} conflicts with #{acc[m.name].path}"
          )
        end

        Map.put(acc, m.name, m)
      end)

    Logger.info("OS Registry: discovered #{map_size(discovered)} new templates")

    {:reply, Map.values(discovered), %{state | discovered: discovered}}
  end

  def handle_call(:prompt_addendums, _from, state) do
    addendums =
      state.connected
      |> Enum.map(fn {_name, manifest} -> template_addendum(manifest) end)
      |> Enum.reject(&is_nil/1)

    {:reply, addendums, state}
  end

  def handle_call(:discovered, _from, state) do
    {:reply, Map.values(state.discovered), state}
  end

  # --- Persistence ---

  defp os_dir, do: Path.expand(Path.join(@config_dir, "os"))

  defp ensure_os_dir do
    dir = os_dir()

    unless File.dir?(dir) do
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> Logger.error("OS Registry: cannot create #{dir}: #{inspect(reason)}")
      end
    end
  end

  defp persist(%Manifest{} = manifest) do
    path = Path.join(os_dir(), "#{sanitize_name(manifest.name)}.json")
    json = manifest |> Manifest.to_map() |> Jason.encode!(pretty: true)

    case File.write(path, json) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("OS Registry: failed to persist '#{manifest.name}': #{inspect(reason)}")
    end
  end

  defp remove_persisted(name) do
    path = Path.join(os_dir(), "#{sanitize_name(name)}.json")
    File.rm(path)
  end

  defp load_persisted do
    dir = os_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce(%{}, fn filename, acc ->
          path = Path.join(dir, filename)

          case load_persisted_file(path) do
            {:ok, manifest} -> Map.put(acc, manifest.name, manifest)
            :error -> acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  defp load_persisted_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      template_path = data["path"]

      if template_path do
        manifest = Manifest.from_map(data, template_path)

        detected_at =
          case data["detected_at"] do
            nil ->
              DateTime.utc_now()

            iso ->
              case DateTime.from_iso8601(iso) do
                {:ok, dt, _} -> dt
                _ -> DateTime.utc_now()
              end
          end

        {:ok, %{manifest | detected_at: detected_at}}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp validate_paths(connected) do
    Enum.each(connected, fn {name, manifest} ->
      unless File.dir?(manifest.path) do
        Logger.warning(
          "OS Registry: '#{name}' path not available (#{manifest.path}) — will retry on next scan"
        )
      end
    end)
  end

  # --- Prompt Generation ---

  defp template_addendum(%Manifest{} = m) do
    modules_text =
      case m.modules do
        [] ->
          ""

        mods ->
          mod_lines =
            Enum.map(mods, fn mod ->
              "  - **#{mod.name}** (#{mod.id}): #{mod.description}"
            end)

          "\nModules:\n#{Enum.join(mod_lines, "\n")}"
      end

    api_text =
      case m.api do
        nil ->
          ""

        api ->
          base = api["base_url"] || "unknown"
          auth = api["auth"]
          auth_str = if auth, do: " (auth: #{auth})", else: ""
          "\nAPI: #{base}#{auth_str}"
      end

    stack_text =
      case m.stack do
        nil -> ""
        s when map_size(s) == 0 -> ""
        s -> " [#{format_stack_inline(s)}]"
      end

    skills_text =
      case m.skills do
        [] ->
          ""

        skills ->
          skill_lines =
            Enum.map(skills, fn s ->
              "  - #{s.name}: #{s.description} → #{s.endpoint}"
            end)

          "\nAvailable actions:\n#{Enum.join(skill_lines, "\n")}"
      end

    """
    ## Connected OS: #{m.name}#{stack_text}
    #{m.description || "No description"}
    Path: #{m.path}#{api_text}#{modules_text}#{skills_text}

    You are integrated with #{m.name}. You can read its files, understand its structure,
    and help the user work within it. Use file_read to explore its codebase when needed.
    """
  end

  defp format_stack_inline(stack) when is_map(stack) do
    stack
    |> Enum.map(fn {k, v} -> "#{k}:#{v}" end)
    |> Enum.join(", ")
  end

  defp format_stack_inline(_), do: ""

  defp sanitize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
    |> String.trim("_")
  end
end
