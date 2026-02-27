defmodule OptimalSystemAgent.Python.Supervisor do
  @moduledoc """
  Supervisor for Python sidecar processes.
  Started conditionally when python_sidecar_enabled is true.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      OptimalSystemAgent.Python.Sidecar
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
