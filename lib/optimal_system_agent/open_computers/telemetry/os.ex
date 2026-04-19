defmodule OptimalSystemAgent.OpenComputers.Telemetry.Os do
  @moduledoc """
  Operating system identification for the host.
  Produces the `%{kind, version, arch}` shape included in the hello frame.
  """

  @spec info() :: %{kind: String.t(), version: String.t(), arch: String.t()}
  def info do
    {_family, os} = :os.type()

    %{
      kind: kind(os),
      version: version(os),
      arch: :erlang.system_info(:system_architecture) |> to_string()
    }
  end

  defp kind(:darwin), do: "darwin"
  defp kind(:linux), do: "linux"
  defp kind(:nt), do: "windows"
  defp kind(other), do: to_string(other)

  defp version(:darwin), do: exec("sw_vers", ["-productVersion"])
  defp version(:linux), do: read_os_release_version() || "unknown"
  defp version(:nt), do: "windows"
  defp version(_), do: "unknown"

  defp read_os_release_version do
    case File.read("/etc/os-release") do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, "=", parts: 2) do
            ["VERSION_ID", v] -> String.trim(v, ~s("))
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  defp exec(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end
end
