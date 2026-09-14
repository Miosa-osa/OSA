defmodule OptimalSystemAgent.OpenComputers.Executor.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-job executor processes. One process per
  active job; executors terminate themselves when done.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_child(module(), map(), (term() -> :ok)) :: DynamicSupervisor.on_start_child()
  def start_child(module, job, reply, context \\ []) do
    spec = %{
      id: make_ref(),
      start:
        {module, :start_link, if(context == [], do: [job, reply], else: [job, reply, context])},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
