defmodule OptimalSystemAgent.Sidecar.Manager do
  @moduledoc """
  Unified sidecar lifecycle manager.

  Responsibilities:
  - Polls `health_check/0` on all registered sidecars every 30s
  - Updates the `Sidecar.Registry` with current health
  - Provides `dispatch/3` — unified entry point for all sidecar calls:
    find by capability → check circuit breaker → call → update breaker
  - Emits telemetry events for observability
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Sidecar.{Registry, CircuitBreaker, Telemetry}

  @health_interval 30_000

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatch a request to a sidecar by capability.

  Finds a healthy sidecar that provides the given capability, checks the
  circuit breaker, calls the sidecar, and updates the breaker on success/failure.

  ## Examples

      Sidecar.Manager.dispatch(:tokenization, "count_tokens", %{"text" => "hello"})
      Sidecar.Manager.dispatch(:embeddings, "embed", %{"text" => "hello"}, 30_000)
  """
  @spec dispatch(atom(), String.t(), map(), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def dispatch(capability, method, params \\ %{}, timeout \\ 10_000) do
    case find_healthy_sidecar(capability) do
      {:ok, sidecar_module} ->
        if CircuitBreaker.allow?(sidecar_module) do
          start_time = Telemetry.call_start(sidecar_module, method, params)

          case sidecar_module.call(method, params, timeout) do
            {:ok, _} = result ->
              CircuitBreaker.record_success(sidecar_module)
              Telemetry.call_stop(start_time, sidecar_module, method, result)
              result

            {:error, _} = error ->
              CircuitBreaker.record_failure(sidecar_module)
              Telemetry.call_exception(start_time, sidecar_module, method, error)
              error
          end
        else
          {:error, :circuit_open}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "List all registered sidecars with their health status."
  @spec status() :: [map()]
  def status, do: Registry.all()

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    Registry.init()
    CircuitBreaker.init()
    schedule_health_poll()
    Logger.info("[Sidecar.Manager] Started — polling health every #{@health_interval}ms")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:health_poll, state) do
    poll_all_health()
    schedule_health_poll()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp find_healthy_sidecar(capability) do
    case Registry.find_by_capability(capability) do
      [] ->
        {:error, {:no_sidecar, capability}}

      sidecars ->
        # Prefer :ready, then :degraded, then :starting
        priority = [:ready, :degraded, :starting]

        best =
          Enum.find_value(priority, fn health ->
            Enum.find(sidecars, fn {_mod, _pid, h} -> h == health end)
          end)

        case best do
          {mod, _pid, _health} -> {:ok, mod}
          nil -> {:error, {:no_healthy_sidecar, capability}}
        end
    end
  end

  defp poll_all_health do
    for %{name: name} <- Registry.all() do
      try do
        health = name.health_check()
        Registry.update_health(name, health)
        Telemetry.health(name, health)
      rescue
        e ->
          Logger.warning("[Sidecar.Manager] Health check failed for #{inspect(name)}: #{Exception.message(e)}")
          Registry.update_health(name, :unavailable)
          Telemetry.health(name, :unavailable)
      end
    end
  end

  defp schedule_health_poll do
    Process.send_after(self(), :health_poll, @health_interval)
  end
end
