defmodule OptimalSystemAgent.OpenComputers.Telemetry.Memory do
  @moduledoc "Host memory statistics via `:memsup`. Returns MB values. Safe on failure — returns 0."

  @compile {:no_warn_undefined, [:memsup]}

  @spec total_mb() :: non_neg_integer()
  def total_mb, do: reduce(:total_memory)

  @spec used_mb() :: non_neg_integer()
  def used_mb do
    data = safe_fetch()
    total = Keyword.get(data, :total_memory, 0)
    free = Keyword.get(data, :free_memory, 0)
    to_mb(total - free)
  end

  @spec free_mb() :: non_neg_integer()
  def free_mb, do: reduce(:free_memory)

  defp reduce(key) do
    case safe_fetch() |> Keyword.get(key) do
      nil -> 0
      bytes -> to_mb(bytes)
    end
  end

  defp safe_fetch do
    :memsup.get_system_memory_data()
  rescue
    _ -> []
  end

  defp to_mb(bytes) when is_integer(bytes) and bytes > 0, do: div(bytes, 1_048_576)
  defp to_mb(_), do: 0
end
