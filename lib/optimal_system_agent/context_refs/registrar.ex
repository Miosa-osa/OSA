defmodule OptimalSystemAgent.ContextRefs.Registrar do
  @moduledoc """
  Registers the context_refs hook at startup.

  Uses restart: :temporary — the Task registers the hook into ETS and exits.
  The hook function lives in ETS and survives the registrar process exit.
  """

  def start_link(_opts) do
    Task.start_link(fn ->
      OptimalSystemAgent.Agent.Hooks.register(
        :user_prompt_submit,
        "context_refs",
        &OptimalSystemAgent.ContextRefs.Hook.user_prompt_submit/1,
        priority: 20
      )
    end)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end
end
