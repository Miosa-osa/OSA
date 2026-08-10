defmodule OptimalSystemAgent.Plugins.Loader do
  @moduledoc """
  Boot-time plugin discovery and registration.

  Scans `~/.osa/plugins/*.exs` at boot, compiles each file, and registers
  any modules that implement `Tools.Behaviour` or `MiosaTools.Behaviour`
  with the Tools.Registry. Also registers any modules implementing
  `ContextEngine` with the ContextEngine.Router.

  ## Plugin file format

  Each `.exs` file is plain Elixir source. It should define one or more
  modules implementing a known behaviour. Example:

      # ~/.osa/plugins/my_tool.exs
      defmodule MyApp.WeatherTool do
        @behaviour OptimalSystemAgent.Tools.Behaviour

        @impl true
        def name, do: "get_weather"

        @impl true
        def description, do: "Get current weather for a city"

        @impl true
        def parameters do
          %{
            type: "object",
            properties: %{
              city: %{type: "string", description: "City name"}
            },
            required: ["city"]
          }
        end

        @impl true
        def execute(%{"city" => city}) do
          {:ok, "Weather in \#{city}: sunny, 72F"}
        end

        @impl true
        def safety, do: :read_only
      end

  ## Discovery

  1. On boot, `load/0` is called from `application.ex` after `Agents.Registry.load()`.
  2. It reads `~/.osa/plugins/` (created if missing).
  3. Each `.exs` file is compiled with `Code.compile_string/1`.
  4. Newly-defined modules are inspected for known behaviours.
  5. Tool modules are registered with `Tools.Registry.register/1`.
  6. ContextEngine modules are registered with `ContextEngine.Router.register/2`.
  7. Results are logged.

  ## Safety

  Plugin files are arbitrary Elixir code — they run in the same VM as the
  agent. Only the operator can write to `~/.osa/plugins/`, so this is safe
  by default. A crash in one plugin file does not prevent others from
  loading.
  """

  require Logger

  alias OptimalSystemAgent.ConfigFile

  @plugin_dir "plugins"

  @doc "Load all plugins from `~/.osa/plugins/`."
  @spec load() :: {:ok, [{module(), atom()}]} | {:error, term()}
  def load do
    dir = plugin_dir()

    case File.ls(dir) do
      {:ok, files} ->
        exs_files = Enum.filter(files, &String.ends_with?(&1, ".exs"))
        results = Enum.flat_map(exs_files, &load_file(&1, dir))
        Logger.info("Plugins.Loader: loaded #{length(results)} plugin(s) from #{dir}")
        {:ok, results}

      {:error, :enoent} ->
        File.mkdir_p(dir)
        Logger.info("Plugins.Loader: created plugin directory #{dir}")
        {:ok, []}

      {:error, reason} ->
        Logger.warning("Plugins.Loader: failed to read #{dir}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Load a single plugin file. Returns `[{module, behaviour_type}]`."
  @spec load_file(String.t(), String.t() | nil) :: [{module(), atom()}]
  def load_file(filename, dir \\ nil) do
    path = if dir, do: Path.join(dir, filename), else: filename
    abs_path = Path.expand(path)

    Logger.info("Plugins.Loader: loading #{abs_path}")

    case File.read(abs_path) do
      {:ok, source} ->
        compile_and_register(source, abs_path)

      {:error, reason} ->
        Logger.warning("Plugins.Loader: cannot read #{abs_path}: #{inspect(reason)}")
        []
    end
  end

  defp plugin_dir do
    Path.join(ConfigFile.config_dir(), @plugin_dir)
  end

  defp compile_and_register(source, path) do
    try do
      # Compile the source — returns list of {module, binary} tuples
      modules_before = :code.all_loaded() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      _results = Code.compile_string(source, file: path)

      modules_after = :code.all_loaded() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      new_modules = MapSet.difference(modules_after, modules_before) |> MapSet.to_list()

      registered = Enum.flat_map(new_modules, &register_module/1)

      if registered == [] do
        Logger.warning("Plugins.Loader: no known behaviours found in #{path}")
      end

      registered
    rescue
      e ->
        Logger.error("Plugins.Loader: failed to compile #{path}: #{Exception.message(e)}")
        []
    end
  end

  defp register_module(mod) do
    behaviours = module_behaviours(mod)

    Enum.flat_map(behaviours, fn behaviour ->
      case behaviour do
        OptimalSystemAgent.Tools.Behaviour ->
          try do
            OptimalSystemAgent.Tools.Registry.register(mod)
            Logger.info("Plugins.Loader: registered tool #{inspect(mod)}")
            [{mod, :tool}]
          rescue
            e ->
              Logger.warning(
                "Plugins.Loader: failed to register tool #{inspect(mod)}: #{Exception.message(e)}"
              )

              []
          end

        MiosaTools.Behaviour ->
          try do
            OptimalSystemAgent.Tools.Registry.register(mod)
            Logger.info("Plugins.Loader: registered miosa-tool #{inspect(mod)}")
            [{mod, :miosa_tool}]
          rescue
            e ->
              Logger.warning(
                "Plugins.Loader: failed to register miosa-tool #{inspect(mod)}: #{Exception.message(e)}"
              )

              []
          end

        OptimalSystemAgent.Agent.ContextEngine ->
          try do
            name = module_name(mod)
            OptimalSystemAgent.Agent.ContextEngine.Router.register(name, mod)
            Logger.info("Plugins.Loader: registered context-engine #{inspect(mod)} as :#{name}")
            [{mod, :context_engine}]
          rescue
            e ->
              Logger.warning(
                "Plugins.Loader: failed to register context-engine #{inspect(mod)}: #{Exception.message(e)}"
              )

              []
          end

        _ ->
          []
      end
    end)
  end

  # Extract the short name for a context engine module (e.g. MyApp.Engine -> :my_app_engine)
  defp module_name(mod) do
    mod
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.downcase()
    |> String.replace(".", "_")
    |> String.to_atom()
  end

  # Get the list of behaviours a module declares
  defp module_behaviours(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        try do
          mod.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end
end
