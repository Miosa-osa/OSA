defmodule OptimalSystemAgent.Sidecar.Behaviour do
  @moduledoc """
  Behaviour contract for all sidecar processes (Go, Python, Rust-backed, etc.).

  Every sidecar GenServer must implement:
  - `call/3`          — send a JSON-RPC method with params, await result
  - `health_check/0`  — return current health status
  - `capabilities/0`  — list of atoms describing what this sidecar can do

  The `Sidecar.Manager` uses these callbacks to route requests by capability,
  monitor health, and integrate with the circuit breaker.
  """

  @type health :: :ready | :starting | :degraded | :unavailable

  @doc "Invoke a JSON-RPC method on the sidecar."
  @callback call(method :: String.t(), params :: map(), timeout :: pos_integer()) ::
              {:ok, term()} | {:error, term()}

  @doc "Return the current health status of the sidecar."
  @callback health_check() :: health()

  @doc "List capabilities this sidecar provides (e.g., [:tokenization, :embeddings])."
  @callback capabilities() :: [atom()]
end
