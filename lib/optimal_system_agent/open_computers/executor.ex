defmodule OptimalSystemAgent.OpenComputers.Executor do
  @moduledoc """
  Job-execution facade. When `OpenComputers.Session.FrameRouter`
  receives a `{:job, _}` frame, it calls `dispatch/2`. This module
  picks the appropriate per-mode executor based on `job.kind`, spawns
  it under `Executor.Supervisor`, and returns quickly — the job runs
  asynchronously and reports back via the passed reply callback.

  ## Modes

    * `:exec_on_host`          → `Direct.Exec` — real
    * `:dispatch_agent`        → `Direct.Agent` — stub (Phase 2)
    * `:stream_native_desktop` → `Direct.Desktop` — stub (Phase 2)
    * `:create_computer`       → slicing / vm_dispatch (Phase 3)
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.{Agent, Desktop, Exec}
  alias OptimalSystemAgent.OpenComputers.Executor.Supervisor, as: ExecSup

  @type job :: %{required(:id) => String.t(), required(:kind) => atom() | String.t(), optional(any()) => any()}
  @type reply :: (term() -> :ok)

  @spec dispatch(job(), reply()) :: :ok | {:error, term()}
  def dispatch(%{kind: kind} = job, reply) when is_function(reply, 1) do
    case mod_for_kind(kind) do
      {:ok, mod} ->
        case ExecSup.start_child(mod, job, reply) do
          {:ok, _pid} ->
            :ok

          {:error, reason} = err ->
            Logger.error("[OpenComputers.Executor] start_child failed: #{inspect(reason)}")
            err
        end

      {:error, :unsupported_kind} = err ->
        reply.(
          {:job_fail, job.id,
           %{reason: :unsupported_kind, message: "no executor for kind=#{inspect(kind)}"}}
        )

        err
    end
  end

  defp mod_for_kind(kind) when is_binary(kind), do: mod_for_kind(String.to_existing_atom(kind))
  defp mod_for_kind(:exec_on_host), do: {:ok, Exec}
  defp mod_for_kind(:dispatch_agent), do: {:ok, Agent}
  defp mod_for_kind(:stream_native_desktop), do: {:ok, Desktop}
  defp mod_for_kind(_), do: {:error, :unsupported_kind}
end
