defmodule OptimalSystemAgent.Sandbox.Router do
  @moduledoc """
  Routes code execution to the configured sandbox backend.

  Reads config from application env or ~/.osa/sandbox.json.
  Falls back to :host (no sandbox) when nothing is configured.

  ## Usage

      Sandbox.Router.execute("echo hello")
      Sandbox.Router.run_file("/tmp/script.py")
      Sandbox.Router.backend()      # → :host | :docker | :e2b
      Sandbox.Router.available?()   # → true/false
  """
  require Logger

  alias OptimalSystemAgent.Sandbox

  @backends %{
    host: Sandbox.Host,
    docker: Sandbox.Docker,
    e2b: Sandbox.E2B
  }

  @doc "Get the currently configured backend module."
  def backend do
    configured = Application.get_env(:optimal_system_agent, :sandbox_backend, :host)

    case configured do
      mod when is_atom(mod) and is_map_key(@backends, mod) ->
        @backends[mod]

      mod when is_atom(mod) ->
        # Custom module
        if Code.ensure_loaded?(mod), do: mod, else: Sandbox.Host

      _ ->
        Sandbox.Host
    end
  end

  @doc "Check if the configured backend is available."
  def available? do
    backend().available?()
  end

  @doc "Get the backend name for display."
  def backend_name do
    backend().name()
  end

  @doc "Execute a command in the configured sandbox."
  def execute(command, opts \\ []) do
    mod = backend()

    if mod.available?() do
      mod.execute(command, opts)
    else
      Logger.warning("[Sandbox] Backend #{mod.name()} not available, falling back to host")
      Sandbox.Host.execute(command, opts)
    end
  end

  @doc "Run a code file in the configured sandbox."
  def run_file(path, opts \\ []) do
    mod = backend()

    if mod.available?() do
      mod.run_file(path, opts)
    else
      Logger.warning("[Sandbox] Backend #{mod.name()} not available, falling back to host")
      Sandbox.Host.run_file(path, opts)
    end
  end

  @doc "List all registered backends and their availability."
  def list_backends do
    Enum.map(@backends, fn {name, mod} ->
      %{
        name: name,
        module: mod,
        display_name: mod.name(),
        available: mod.available?()
      }
    end)
  end

  @doc """
  Load sandbox configuration from ~/.osa/sandbox.json if it exists.
  Called at boot. Sets application env from the JSON config.
  """
  def load_config do
    path = Path.expand("~/.osa/sandbox.json")

    if File.exists?(path) do
      case File.read(path)
           |> then(fn
             {:ok, c} -> Jason.decode(c)
             e -> e
           end) do
        {:ok, %{"backend" => backend} = config} ->
          atom_backend = String.to_existing_atom(backend)
          Application.put_env(:optimal_system_agent, :sandbox_backend, atom_backend)

          # Load backend-specific config
          if docker_config = config["docker"] do
            Application.put_env(:optimal_system_agent, :sandbox_docker, %{
              image: docker_config["image"],
              memory: docker_config["memory"],
              network: docker_config["network"],
              timeout: docker_config["timeout"]
            })
          end

          if e2b_key = get_in(config, ["e2b", "api_key"]) do
            Application.put_env(:optimal_system_agent, :e2b_api_key, e2b_key)
          end

          Logger.info("[Sandbox] Loaded config: backend=#{backend}")
          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end
end
