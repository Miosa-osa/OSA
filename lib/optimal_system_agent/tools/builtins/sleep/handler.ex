defmodule OptimalSystemAgent.Tools.Builtins.Sleep.Handler do
  @moduledoc """
  Validation, permission, and execution for `sleep`.

  The sleep is a cooperative wait — it polls the abort_ref every 100ms so
  user interrupts terminate the sleep within a tick boundary.
  """

  alias OptimalSystemAgent.Tools.Builtins.Sleep.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @poll_interval_ms 100

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"seconds" => s} = input, _ctx) when is_integer(s) and s > 0 do
    cond do
      s < Constants.min_seconds() ->
        {:error, "seconds must be >= #{Constants.min_seconds()}", -32_602}

      s > Constants.max_seconds() ->
        {:error,
         "seconds must be <= #{Constants.max_seconds()} (#{div(Constants.max_seconds(), 60)}m)",
         -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"seconds" => _}, _ctx),
    do: {:error, "seconds must be a positive integer", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: seconds", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{"seconds" => seconds}, %UseContext{abort_ref: abort_ref}) do
    deadline_ms = System.monotonic_time(:millisecond) + seconds * 1_000
    started_at = System.monotonic_time(:millisecond)

    case wait_until(deadline_ms, abort_ref) do
      :ok ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        {:ok, "Slept for #{format_duration(elapsed_ms)}"}

      :interrupted ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        {:ok, "Sleep interrupted after #{format_duration(elapsed_ms)}"}
    end
  end

  defp wait_until(deadline_ms, abort_ref) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline_ms ->
        :ok

      aborted?(abort_ref) ->
        :interrupted

      true ->
        remaining = deadline_ms - now
        Process.sleep(min(@poll_interval_ms, remaining))
        wait_until(deadline_ms, abort_ref)
    end
  end

  # abort_ref convention: a pid we can poll via Process.alive?/1, or nil.
  defp aborted?(nil), do: false
  defp aborted?(pid) when is_pid(pid), do: not Process.alive?(pid)
  defp aborted?(_), do: false

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_duration(ms) do
    s = div(ms, 1_000)
    "#{div(s, 60)}m#{rem(s, 60)}s"
  end
end
