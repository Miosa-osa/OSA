defmodule OptimalSystemAgent.Skin.Loader do
  @moduledoc "Loads skin YAML files from bundled and user directories."
  require Logger

  alias OptimalSystemAgent.Skin.Schema

  @spec load_all() :: %{String.t() => Schema.t()}
  def load_all do
    bundled = load_from_dir(bundled_dir())
    user = load_from_dir(user_dir())
    # User skins override bundled skins with the same name
    Map.merge(bundled, user)
  end

  @spec load_from_dir(String.t()) :: %{String.t() => Schema.t()}
  def load_from_dir(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("*.{yaml,yml}")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        case load_file(path) do
          {:ok, skin} ->
            Map.put(acc, skin.name, skin)

          {:error, reason} ->
            Logger.warning("[skin] Failed to load #{path}: #{reason}")
            acc
        end
      end)
    else
      %{}
    end
  end

  @spec load_file(String.t()) :: {:ok, Schema.t()} | {:error, String.t()}
  def load_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} when is_map(data) -> Schema.from_map(data)
      {:ok, _} -> {:error, "YAML root must be a map"}
      {:error, err} -> {:error, "YAML parse error: #{inspect(err)}"}
    end
  end

  defp bundled_dir do
    :code.priv_dir(:optimal_system_agent)
    |> to_string()
    |> Path.join("skins")
  end

  defp user_dir, do: Path.expand("~/.osa/skins")
end
