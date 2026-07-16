defmodule OptimalSystemAgent.Sandbox.Router do
  @moduledoc """
  Routes code execution to the configured sandbox backend.

  Reads config from application env or ~/.osa/sandbox.json.
  Falls back to :host (no sandbox) when nothing is configured and sandbox mode is optional.
  In required mode, host execution is blocked unless a non-host sandbox backend is available.

  ## Usage

      Sandbox.Router.execute("echo hello")
      Sandbox.Router.run_file("/tmp/script.py")
      Sandbox.Router.backend()      # → :host | :docker | :e2b | :miosa | :vercel
      Sandbox.Router.available?()   # → true/false
      Sandbox.Router.mode()         # → :optional | :required

  ## Selection precedence

  1. Explicit `:sandbox_backend` in application env (set directly or loaded from
     `~/.osa/sandbox.json`).
  2. Otherwise, env-var auto-detection (see `detect_backend/0`), preferring
     MIOSA (the recommended default) when several backends are configured.
  3. Otherwise, `:host` (no sandbox).

  The Router owns selection, config loading, and host-fallback only — each
  backend is a self-contained module implementing `Sandbox.Behaviour`.
  """
  require Logger

  alias OptimalSystemAgent.Sandbox

  @backends %{
    host: Sandbox.Host,
    docker: Sandbox.Docker,
    e2b: Sandbox.E2B,
    miosa: Sandbox.MIOSA,
    vercel: Sandbox.Vercel
  }

  # Env-var → backend, in preference order. MIOSA (recommended default) wins
  # when multiple credentials are present.
  @env_detection [
    {"MIOSA_PLATFORM_API_KEY", :miosa},
    {"E2B_API_KEY", :e2b},
    {"VERCEL_TOKEN", :vercel}
  ]

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

          if e2b_config = config["e2b"] do
            if key = e2b_config["api_key"] do
              Application.put_env(:optimal_system_agent, :e2b_api_key, key)
            end

            Application.put_env(:optimal_system_agent, :sandbox_e2b, %{
              template: e2b_config["template"],
              timeout_ms: to_ms(e2b_config["timeout"])
            })
          end

          if miosa_config = config["miosa"] do
            if key = miosa_config["api_key"] do
              Application.put_env(:optimal_system_agent, :miosa_platform_api_key, key)
            end

            Application.put_env(:optimal_system_agent, :sandbox_miosa, %{
              size: miosa_config["size"],
              timeout_ms: to_ms(miosa_config["timeout"])
            })
          end

          if vercel_config = config["vercel"] do
            Application.put_env(:optimal_system_agent, :sandbox_vercel, %{
              token: vercel_config["token"],
              team_id: vercel_config["team_id"],
              project_id: vercel_config["project_id"],
              runtime: vercel_config["runtime"],
              timeout_ms: to_ms(vercel_config["timeout"])
            })
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

  @doc """
  Auto-detect a backend from environment variables.

  Returns the first configured backend in preference order (MIOSA preferred),
  or `:host` when nothing is configured. Only consulted when no explicit
  `:sandbox_backend` is set in application env / `~/.osa/sandbox.json`.
  """
  def detect_backend do
    Enum.find_value(@env_detection, :host, fn {env, backend} ->
      if System.get_env(env) not in [nil, ""], do: backend
    end)
  end

  defp configured_backend do
    configured =
      case Application.fetch_env(:optimal_system_agent, :sandbox_backend) do
        {:ok, value} -> value
        :error -> detect_backend()
      end

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

  # JSON config expresses timeouts in seconds; backends want milliseconds.
  defp to_ms(nil), do: nil
  defp to_ms(secs) when is_integer(secs), do: secs * 1000
  defp to_ms(secs) when is_float(secs), do: trunc(secs * 1000)
  defp to_ms(_), do: nil
end
