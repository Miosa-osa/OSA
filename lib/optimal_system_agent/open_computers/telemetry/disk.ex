defmodule OptimalSystemAgent.OpenComputers.Telemetry.Disk do
  @moduledoc "Disk free-space for the root mount via `:disksup`. Returns GB; 0 on failure."

  @compile {:no_warn_undefined, [:disksup]}

  @spec free_gb() :: non_neg_integer()
  def free_gb do
    case :disksup.get_disk_data() do
      data when is_list(data) ->
        data
        |> Enum.find(&root_mount?/1)
        |> extract_free_gb()

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp root_mount?({mount, _, _}) do
    m = to_string(mount)
    m == "/" or m == "C:\\"
  end

  defp extract_free_gb({_, size_kb, pct_used}) do
    free_kb = size_kb - div(size_kb * pct_used, 100)
    div(free_kb, 1_048_576)
  end

  defp extract_free_gb(_), do: 0
end
