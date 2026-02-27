defmodule OptimalSystemAgent.Agent.HeartbeatState do
  @moduledoc """
  GenServer persisting heartbeat check state to ~/.osa/heartbeat_state.json.

  Tracks which checks have been run, their results, and run counts.
  Supports quiet hours configuration via the OSA_QUIET_HOURS env variable
  (format: "23:00-08:00" or "23:00-08:00,12:00-13:00" for multiple ranges).

  State is persisted atomically on every change (write to tmp, then rename).
  """
  use GenServer
  require Logger

  defstruct checks: %{},
            quiet_hours: [],
            state_file: nil

  @default_state_file Path.expand("~/.osa/heartbeat_state.json")

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a check result. Updates run count and persists to disk."
  @spec record_check(atom(), any()) :: :ok
  def record_check(type, result) when is_atom(type) do
    GenServer.cast(__MODULE__, {:record_check, type, result})
  end

  @doc "Get the last check info for a given type."
  @spec last_check(atom()) :: {:ok, map()} | :not_found
  def last_check(type) when is_atom(type) do
    GenServer.call(__MODULE__, {:last_check, type})
  end

  @doc "Check if current UTC time falls within configured quiet hours."
  @spec in_quiet_hours?() :: boolean()
  def in_quiet_hours? do
    GenServer.call(__MODULE__, :in_quiet_hours?)
  end

  @doc "Set quiet hours ranges. Each range is {start_hour, start_min, end_hour, end_min}."
  @spec set_quiet_hours(list(tuple())) :: :ok
  def set_quiet_hours(ranges) when is_list(ranges) do
    GenServer.call(__MODULE__, {:set_quiet_hours, ranges})
  end

  # ── Server callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    state_file = Keyword.get(opts, :state_file, @default_state_file)
    quiet_hours = parse_quiet_hours_env()

    state = %__MODULE__{
      checks: %{},
      quiet_hours: quiet_hours,
      state_file: state_file
    }

    loaded_state = load_from_file(state)

    Logger.info("[Agent.HeartbeatState] Started, state_file=#{state_file}")
    {:ok, loaded_state}
  end

  @impl true
  def handle_cast({:record_check, type, result}, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    existing = Map.get(state.checks, type, %{last_run: nil, result: nil, run_count: 0})

    updated_check = %{
      last_run: now,
      result: result,
      run_count: existing.run_count + 1
    }

    new_checks = Map.put(state.checks, type, updated_check)
    new_state = %{state | checks: new_checks}

    persist_to_file(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:last_check, type}, _from, state) do
    case Map.fetch(state.checks, type) do
      {:ok, check_info} -> {:reply, {:ok, check_info}, state}
      :error -> {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_call(:in_quiet_hours?, _from, state) do
    result = check_quiet_hours(state.quiet_hours, DateTime.utc_now())
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_quiet_hours, ranges}, _from, state) do
    new_state = %{state | quiet_hours: ranges}
    persist_to_file(new_state)
    {:reply, :ok, new_state}
  end

  # ── Private ──────────────────────────────────────────────────────

  defp load_from_file(state) do
    case File.read(state.state_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            checks = deserialize_checks(data["checks"] || %{})
            quiet_hours = deserialize_quiet_hours(data["quiet_hours"] || [])

            %{
              state
              | checks: checks,
                quiet_hours: if(quiet_hours == [], do: state.quiet_hours, else: quiet_hours)
            }

          {:error, reason} ->
            Logger.warning(
              "[Agent.HeartbeatState] Failed to parse state file: #{inspect(reason)}"
            )

            state
        end

      {:error, :enoent} ->
        state

      {:error, reason} ->
        Logger.warning("[Agent.HeartbeatState] Failed to read state file: #{inspect(reason)}")
        state
    end
  end

  defp persist_to_file(state) do
    dir = Path.dirname(state.state_file)
    File.mkdir_p!(dir)

    data = %{
      checks: serialize_checks(state.checks),
      quiet_hours: serialize_quiet_hours(state.quiet_hours)
    }

    tmp_file = state.state_file <> ".tmp"

    try do
      content = Jason.encode!(data, pretty: true)
      File.write!(tmp_file, content)
      File.rename!(tmp_file, state.state_file)
    rescue
      e ->
        Logger.error("[Agent.HeartbeatState] Failed to persist state: #{inspect(e)}")
        File.rm(tmp_file)
    end
  end

  defp serialize_checks(checks) do
    Map.new(checks, fn {type, info} ->
      {Atom.to_string(type),
       %{
         "last_run" => info.last_run,
         "result" => serialize_result(info.result),
         "run_count" => info.run_count
       }}
    end)
  end

  defp deserialize_checks(checks_map) when is_map(checks_map) do
    Map.new(checks_map, fn {type_str, info} ->
      {String.to_atom(type_str),
       %{
         last_run: info["last_run"],
         result: info["result"],
         run_count: info["run_count"] || 0
       }}
    end)
  end

  defp serialize_result(result) when is_atom(result), do: Atom.to_string(result)
  defp serialize_result(result), do: result

  defp serialize_quiet_hours(ranges) do
    Enum.map(ranges, fn {sh, sm, eh, em} ->
      %{"start_hour" => sh, "start_min" => sm, "end_hour" => eh, "end_min" => em}
    end)
  end

  defp deserialize_quiet_hours(ranges) when is_list(ranges) do
    Enum.map(ranges, fn range ->
      {range["start_hour"], range["start_min"], range["end_hour"], range["end_min"]}
    end)
  end

  defp parse_quiet_hours_env do
    case System.get_env("OSA_QUIET_HOURS") do
      nil -> []
      "" -> []
      value -> parse_quiet_hours_string(value)
    end
  end

  @doc false
  def parse_quiet_hours_string(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn range_str ->
      case String.split(range_str, "-", parts: 2) do
        [start_str, end_str] ->
          with {:ok, {sh, sm}} <- parse_time(start_str),
               {:ok, {eh, em}} <- parse_time(end_str) do
            [{sh, sm, eh, em}]
          else
            _ ->
              Logger.warning("[Agent.HeartbeatState] Invalid quiet hours range: #{range_str}")
              []
          end

        _ ->
          Logger.warning("[Agent.HeartbeatState] Invalid quiet hours format: #{range_str}")
          []
      end
    end)
  end

  defp parse_time(str) do
    str = String.trim(str)

    case String.split(str, ":") do
      [h_str, m_str] ->
        with {h, ""} <- Integer.parse(h_str),
             {m, ""} <- Integer.parse(m_str),
             true <- h >= 0 and h <= 23 and m >= 0 and m <= 59 do
          {:ok, {h, m}}
        else
          _ -> {:error, :invalid_time}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc false
  def check_quiet_hours([], _now), do: false

  def check_quiet_hours(ranges, now) do
    current_hour = now.hour
    current_min = now.minute

    Enum.any?(ranges, fn {sh, sm, eh, em} ->
      start_minutes = sh * 60 + sm
      end_minutes = eh * 60 + em
      current_minutes = current_hour * 60 + current_min

      if start_minutes <= end_minutes do
        # Same-day range: e.g., 12:00-13:00
        current_minutes >= start_minutes and current_minutes < end_minutes
      else
        # Overnight range: e.g., 23:00-08:00
        current_minutes >= start_minutes or current_minutes < end_minutes
      end
    end)
  end
end
