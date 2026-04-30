defmodule OptimalSystemAgent.Sandbox.Router do
  @moduledoc """
  Routes code execution to the configured sandbox backend.

  Reads config from application env or ~/.osa/sandbox.json.
  Falls back to :host (no sandbox) when nothing is configured and sandbox mode is optional.
  In required mode, host execution is blocked unless a non-host sandbox backend is available.

  ## Usage

      Sandbox.Router.execute("echo hello")
      Sandbox.Router.run_file("/tmp/script.py")
      Sandbox.Router.backend()      # → :host | :docker | :e2b
      Sandbox.Router.available?()   # → true/false
      Sandbox.Router.mode()         # → :optional | :required
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
    case configured_backend() do
      {:ok, mod} -> mod
      {:error, _reason} -> Sandbox.Host
    end
  end

  @doc "Get sandbox enforcement mode."
  def mode do
    configured =
      case Application.fetch_env(:optimal_system_agent, :sandbox_mode) do
        {:ok, value} -> value
        :error -> Application.get_env(:optimal_system_agent, :sandbox_required, false)
      end

    normalize_mode(configured)
  end

  @doc "Check whether sandbox enforcement is required."
  def required? do
    mode() == :required
  end

  @doc "Check if the configured backend is available."
  def available? do
    case configured_backend() do
      {:ok, Sandbox.Host} -> mode() != :required
      {:ok, mod} -> mod.available?()
      {:error, _reason} -> false
    end
  end

  @doc "Get the backend name for display."
  def backend_name do
    backend().name()
  end

  @doc "Execute a command in the configured sandbox."
  def execute(command, opts \\ []) do
    route(:execute, [command, opts])
  end

  @doc "Run a code file in the configured sandbox."
  def run_file(path, opts \\ []) do
    route(:run_file, [path, opts])
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
          maybe_put_mode(config)

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

  defp route(fun, args) do
    case configured_backend() do
      {:ok, Sandbox.Host} ->
        if mode() == :required do
          {:error, unavailable_message(Sandbox.Host)}
        else
          apply(Sandbox.Host, fun, args)
        end

      {:ok, mod} ->
        if mod.available?() do
          apply(mod, fun, args)
        else
          handle_unavailable(mod, fun, args)
        end

      {:error, reason} ->
        handle_invalid_backend(reason, fun, args)
    end
  end

  defp handle_unavailable(mod, fun, args) do
    if mode() == :required do
      {:error, unavailable_message(mod)}
    else
      Logger.warning("[Sandbox] Backend #{mod.name()} not available, falling back to host")
      apply(Sandbox.Host, fun, args)
    end
  end

  defp handle_invalid_backend(reason, fun, args) do
    if mode() == :required do
      {:error, "Sandbox required but configured backend is invalid: #{reason}"}
    else
      Logger.warning("[Sandbox] Invalid backend #{reason}, falling back to host")
      apply(Sandbox.Host, fun, args)
    end
  end

  defp unavailable_message(Sandbox.Host) do
    "Sandbox required but configured backend is host (no sandbox)"
  end

  defp unavailable_message(mod) do
    "Sandbox required but backend #{mod.name()} is not available"
  end

  defp configured_backend do
    configured = Application.get_env(:optimal_system_agent, :sandbox_backend, :host)

    case configured do
      mod when is_atom(mod) and is_map_key(@backends, mod) ->
        {:ok, @backends[mod]}

      mod when is_atom(mod) ->
        # Custom module
        if Code.ensure_loaded?(mod), do: {:ok, mod}, else: {:error, inspect(mod)}

      other ->
        {:error, inspect(other)}
    end
  end

  defp maybe_put_mode(config) do
    cond do
      Map.has_key?(config, "mode") ->
        Application.put_env(:optimal_system_agent, :sandbox_mode, normalize_mode(config["mode"]))

      Map.has_key?(config, "required") ->
        Application.put_env(
          :optimal_system_agent,
          :sandbox_mode,
          normalize_mode(config["required"])
        )

      true ->
        :ok
    end
  end

  defp normalize_mode(mode) when mode in ["required", :required, true], do: :required
  defp normalize_mode(_mode), do: :optional
end
