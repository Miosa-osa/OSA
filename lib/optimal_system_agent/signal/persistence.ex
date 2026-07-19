defmodule OptimalSystemAgent.Signal.Persistence do
  use GenServer
  require Logger
  import Ecto.Query

  alias OptimalSystemAgent.Store.Repo
  alias OptimalSystemAgent.Store.Signal
  alias OptimalSystemAgent.Events.Bus

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{handler_ref: nil}, {:continue, :register_bus_handler}}
  end

  # Deferred to handle_continue so a boot-time hiccup on Events.Bus (e.g.
  # transiently unreachable while Infrastructure is still settling under
  # load) degrades Signal.Persistence instead of crashing it and taking
  # down the whole AgentServices supervisor.
  @impl true
  def handle_continue(:register_bus_handler, state) do
    try do
      ref = Bus.register_handler(:signal_classified, &handle_signal_event/1)
      {:noreply, %{state | handler_ref: ref}}
    catch
      :exit, reason ->
        Logger.warning("[Persistence] Events.Bus unavailable, will retry: #{inspect(reason)}")
        Process.send_after(self(), :retry_register_bus_handler, 500)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:retry_register_bus_handler, state) do
    {:noreply, state, {:continue, :register_bus_handler}}
  end

  @impl true
  def terminate(_reason, %{handler_ref: nil}), do: :ok

  def terminate(_reason, %{handler_ref: ref}) do
    Bus.unregister_handler(:signal_classified, ref)
    :ok
  end

  defp handle_signal_event(%{payload: %{signal: signal} = payload}) do
    attrs = %{
      session_id: payload[:session_id],
      channel: to_string(signal.channel),
      mode: to_string(signal.mode),
      genre: to_string(signal.genre),
      type: signal.type || "general",
      format: to_string(signal.format),
      weight: signal.weight || 0.5,
      input_preview: truncate(signal.raw, 200),
      confidence: to_string(signal.confidence || :high),
      metadata: %{source: to_string(payload[:source])}
    }

    case persist_signal(attrs) do
      {:ok, record} ->
        broadcast_signal(record)

      {:error, changeset} ->
        Logger.warning("[Persistence] Failed to persist signal: #{inspect(changeset.errors)}")
    end
  end

  defp handle_signal_event(_), do: :ok

  def persist_signal(attrs) do
    %Signal{}
    |> Signal.changeset(attrs)
    |> Repo.insert()
  end

  def list_signals(opts \\ []) do
    Signal
    |> apply_filters(opts)
    |> order_by([s], desc: s.inserted_at)
    |> limit_offset(opts)
    |> Repo.all()
  end

  def recent_signals(n \\ 20) do
    list_signals(limit: n)
  end

  def signal_stats do
    total = Repo.aggregate(Signal, :count)
    avg_weight = Repo.aggregate(Signal, :avg, :weight) || 0.0

    by_mode =
      Signal
      |> group_by([s], s.mode)
      |> select([s], {s.mode, count(s.id)})
      |> Repo.all()
      |> Map.new()

    by_channel =
      Signal
      |> group_by([s], s.channel)
      |> select([s], {s.channel, count(s.id)})
      |> Repo.all()
      |> Map.new()

    by_type =
      Signal
      |> group_by([s], s.type)
      |> select([s], {s.type, count(s.id)})
      |> Repo.all()
      |> Map.new()

    by_tier =
      Signal
      |> group_by([s], s.tier)
      |> select([s], {s.tier, count(s.id)})
      |> Repo.all()
      |> Map.new()

    %{
      total: total,
      avg_weight: Float.round(avg_weight * 1.0, 3),
      by_mode: by_mode,
      by_channel: by_channel,
      by_type: by_type,
      by_tier: by_tier
    }
  end

  def signal_patterns(opts \\ []) do
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    recent =
      Signal
      |> where([s], s.inserted_at >= ^since)
      |> Repo.all()

    top_agents =
      recent
      |> Enum.filter(& &1.agent_name)
      |> Enum.frequencies_by(& &1.agent_name)
      |> Enum.sort_by(fn {_, c} -> c end, :desc)
      |> Enum.take(5)
      |> Map.new()

    avg_weight =
      case recent do
        [] ->
          0.0

        list ->
          list |> Enum.map(& &1.weight) |> Enum.sum() |> Kernel./(length(list)) |> Float.round(3)
      end

    peak_hours =
      recent
      |> Enum.frequencies_by(fn s ->
        s.inserted_at |> NaiveDateTime.to_time() |> Map.get(:hour)
      end)
      |> Enum.sort_by(fn {_, c} -> c end, :desc)
      |> Enum.take(5)
      |> Map.new()

    daily_counts =
      recent
      |> Enum.frequencies_by(fn s -> NaiveDateTime.to_date(s.inserted_at) end)
      |> Enum.sort_by(fn {d, _} -> d end)
      |> Enum.map(fn {date, count} -> %{date: Date.to_string(date), count: count} end)

    %{
      avg_weight: avg_weight,
      top_agents: top_agents,
      peak_hours: peak_hours,
      daily_counts: daily_counts,
      total_in_period: length(recent)
    }
  end

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:mode, mode}, q -> where(q, [s], s.mode == ^mode)
      {:genre, genre}, q -> where(q, [s], s.genre == ^genre)
      {:type, type}, q -> where(q, [s], s.type == ^type)
      {:channel, channel}, q -> where(q, [s], s.channel == ^channel)
      {:tier, tier}, q -> where(q, [s], s.tier == ^tier)
      {:weight_min, min}, q -> where(q, [s], s.weight >= ^min)
      {:weight_max, max}, q -> where(q, [s], s.weight <= ^max)
      {:from, from}, q -> where(q, [s], s.inserted_at >= ^from)
      {:to, to}, q -> where(q, [s], s.inserted_at <= ^to)
      _, q -> q
    end)
  end

  defp limit_offset(query, opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query
    |> limit(^limit)
    |> offset(^offset)
  end

  defp truncate(nil, _), do: nil
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max)

  defp broadcast_signal(record) do
    payload = %{
      id: record.id,
      session_id: record.session_id,
      channel: record.channel,
      mode: record.mode,
      genre: record.genre,
      type: record.type,
      format: record.format,
      weight: record.weight,
      tier: record.tier,
      input_preview: record.input_preview,
      confidence: record.confidence,
      inserted_at: NaiveDateTime.to_iso8601(record.inserted_at)
    }

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:signals",
      {:signal_new, payload}
    )
  end
end
