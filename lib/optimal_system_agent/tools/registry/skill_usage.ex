defmodule OptimalSystemAgent.Tools.Registry.SkillUsage do
  @moduledoc """
  Lightweight ETS-backed skill usage tracking.

  Tracks use_count, first_used_at, last_used_at per skill name.
  Persisted to ~/.osa/skill-usage.json on shutdown, loaded on boot.
  """
  require Logger

  @table :osa_skill_usage
  @persist_path "~/.osa/skill-usage.json"

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
    end

    load_persisted()
  end

  @spec record_use(String.t()) :: :ok
  def record_use(skill_name) when is_binary(skill_name) do
    now = DateTime.utc_now()

    case :ets.lookup(@table, skill_name) do
      [{^skill_name, count, first, _last}] ->
        :ets.insert(@table, {skill_name, count + 1, first, now})

      [] ->
        :ets.insert(@table, {skill_name, 1, now, now})
    end

    :ok
  rescue
    _ -> :ok
  end

  def record_use(_), do: :ok

  @spec get_usage(String.t()) :: map()
  def get_usage(skill_name) do
    case :ets.lookup(@table, skill_name) do
      [{^skill_name, count, first, last}] ->
        %{use_count: count, first_used_at: first, last_used_at: last}

      [] ->
        %{use_count: 0, first_used_at: nil, last_used_at: nil}
    end
  rescue
    _ -> %{use_count: 0, first_used_at: nil, last_used_at: nil}
  end

  @spec all_usage() :: map()
  def all_usage do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, count, first, last} ->
      {name, %{use_count: count, first_used_at: first, last_used_at: last}}
    end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  @spec persist() :: :ok
  def persist do
    data =
      all_usage()
      |> Enum.map(fn {name, stats} ->
        {name,
         %{
           use_count: stats.use_count,
           first_used_at: stats.first_used_at && DateTime.to_iso8601(stats.first_used_at),
           last_used_at: stats.last_used_at && DateTime.to_iso8601(stats.last_used_at)
         }}
      end)
      |> Map.new()

    path = Path.expand(@persist_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
    :ok
  rescue
    e ->
      Logger.warning("[SkillUsage] Persist failed: #{Exception.message(e)}")
      :ok
  end

  defp load_persisted do
    path = Path.expand(@persist_path)

    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, data} <- Jason.decode(content) do
        Enum.each(data, fn {name, stats} ->
          count = stats["use_count"] || 0
          first = parse_dt(stats["first_used_at"])
          last = parse_dt(stats["last_used_at"])
          :ets.insert(@table, {name, count, first, last})
        end)
      else
        _ -> :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil
end
