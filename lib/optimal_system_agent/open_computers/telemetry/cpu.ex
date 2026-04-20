defmodule OptimalSystemAgent.OpenComputers.Telemetry.Cpu do
  @moduledoc "CPU telemetry via `:cpu_sup`. Normalizes avg1 by 256 to a conventional load-average float."

  @compile {:no_warn_undefined, [:cpu_sup]}

  @spec cores() :: non_neg_integer()
  def cores, do: :erlang.system_info(:logical_processors_available)

  @spec load_avg_1m() :: float()
  def load_avg_1m do
    case :cpu_sup.avg1() do
      n when is_integer(n) -> n / 256
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  end
end
