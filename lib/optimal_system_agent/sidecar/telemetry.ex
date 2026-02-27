defmodule OptimalSystemAgent.Sidecar.Telemetry do
  @moduledoc """
  Telemetry event catalog for the sidecar subsystem.

  Events emitted:
  - `[:osa, :sidecar, :call, :start]`     — before dispatching a sidecar call
  - `[:osa, :sidecar, :call, :stop]`      — after successful sidecar call
  - `[:osa, :sidecar, :call, :exception]`  — on sidecar call failure
  - `[:osa, :sidecar, :health]`           — periodic health check result
  - `[:osa, :sidecar, :circuit_breaker]`  — circuit breaker state transitions
  """

  @doc "Emit a call start event. Returns the start monotonic time for duration calculation."
  @spec call_start(module(), String.t(), map()) :: integer()
  def call_start(sidecar, method, params) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:osa, :sidecar, :call, :start],
      %{system_time: System.system_time()},
      %{sidecar: sidecar, method: method, params_size: map_byte_size(params)}
    )

    start_time
  end

  @doc "Emit a call stop event with duration."
  @spec call_stop(integer(), module(), String.t(), term()) :: :ok
  def call_stop(start_time, sidecar, method, result) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:osa, :sidecar, :call, :stop],
      %{duration: duration},
      %{sidecar: sidecar, method: method, result: result_tag(result)}
    )

    :ok
  end

  @doc "Emit a call exception event."
  @spec call_exception(integer(), module(), String.t(), term()) :: :ok
  def call_exception(start_time, sidecar, method, reason) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:osa, :sidecar, :call, :exception],
      %{duration: duration},
      %{sidecar: sidecar, method: method, reason: reason}
    )

    :ok
  end

  @doc "Emit a health check event."
  @spec health(module(), atom()) :: :ok
  def health(sidecar, status) do
    :telemetry.execute(
      [:osa, :sidecar, :health],
      %{system_time: System.system_time()},
      %{sidecar: sidecar, status: status}
    )

    :ok
  end

  @doc "Emit a circuit breaker state change event."
  @spec circuit_breaker(module(), atom(), atom()) :: :ok
  def circuit_breaker(sidecar, from_state, to_state) do
    :telemetry.execute(
      [:osa, :sidecar, :circuit_breaker],
      %{system_time: System.system_time()},
      %{sidecar: sidecar, from: from_state, to: to_state}
    )

    :ok
  end

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, _}), do: :error
  defp result_tag(_), do: :unknown

  defp map_byte_size(params) when is_map(params) do
    params
    |> Jason.encode!()
    |> byte_size()
  rescue
    _ -> 0
  end

  defp map_byte_size(_), do: 0
end
