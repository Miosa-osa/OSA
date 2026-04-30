defmodule OptimalSystemAgent.Memory.Learning do
  @moduledoc """
  SICA learning engine — See → Introspect → Capture → Adapt.

  Implements the four-phase learning cycle for OSA:

    1. **SEE/OBSERVE**   — Record every tool invocation as an observation
    2. **INTROSPECT**    — Classify failures with VIGIL; detect recurring patterns
    3. **CAPTURE**       — Persist patterns to SQLite via `OptimalSystemAgent.Store.Pattern`
    4. **ADAPT**         — Surface recommendations from mature (≥5 occurrences) patterns

  Consolidation is delegated to `OptimalSystemAgent.Memory.Consolidator`.

  ## Consolidation schedule

    - Every **5** interactions: incremental consolidation (merge similar, prune stale)
    - Every **50** interactions: full consolidation (cross-reference errors + patterns)

  ## Working memory

  Recent observations are kept in ETS table `:osa_learning` (last 500 entries).
  Pattern data is persisted to SQLite so it survives restarts.

  ## Usage

      :ok = OptimalSystemAgent.Memory.Learning.observe(%{
        type: :success, tool_name: "file_read", duration_ms: 42
      })

      :ok = OptimalSystemAgent.Memory.Learning.correction("used tabs", "use spaces always")

      :ok = OptimalSystemAgent.Memory.Learning.error("file_write", "enoent: no such file", %{})

      {:ok, patterns} = OptimalSystemAgent.Memory.Learning.patterns()
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Memory.{VIGIL, Observation, Consolidator}

  @ets_table :osa_learning
  @max_observations 500
  @incremental_every 5
  @full_every 50

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a tool invocation. Fire-and-forget."
  @spec observe(map()) :: :ok
  def observe(interaction) when is_map(interaction) do
    GenServer.cast(__MODULE__, {:observe, interaction})
  end

  @doc "Record a user correction — what was wrong and what is right."
  @spec correction(String.t(), String.t()) :: :ok
  def correction(what_was_wrong, what_is_right)
      when is_binary(what_was_wrong) and is_binary(what_is_right) do
    GenServer.cast(__MODULE__, {:correction, what_was_wrong, what_is_right})
  end

  @doc "Record a tool error with VIGIL classification."
  @spec error(String.t(), String.t(), map()) :: :ok
  def error(tool_name, error_message, context \\ %{})
      when is_binary(tool_name) and is_binary(error_message) do
    GenServer.cast(__MODULE__, {:error, tool_name, error_message, context})
  end

  @doc "Return all persisted patterns from SQLite."
  @spec patterns() :: {:ok, [map()]}
  def patterns do
    GenServer.call(__MODULE__, :patterns, :infinity)
  end

  @doc "Return stored solutions (correction/solution category patterns)."
  @spec solutions() :: {:ok, [map()]}
  def solutions do
    GenServer.call(__MODULE__, :solutions, :infinity)
  end

  @doc "Force a full consolidation cycle. Returns a report map."
  @spec consolidate() :: {:ok, map()}
  def consolidate do
    GenServer.call(__MODULE__, :consolidate, :infinity)
  end

  @doc "Return consolidation stats from GenServer state."
  @spec metrics() :: {:ok, map()}
  def metrics do
    GenServer.call(__MODULE__, :metrics, :infinity)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    create_ets_table()
    Logger.info("[Memory.Learning] SICA engine started")

    {:ok,
     %{
       interaction_count: 0,
       consolidation_count: 0,
       last_consolidation: nil
     }}
  end

  @impl true
  def handle_cast({:observe, interaction}, state) do
    {:noreply, do_observe(interaction, state)}
  end

  @impl true
  def handle_cast({:correction, wrong, right}, state) do
    case Observation.new(%{
           type: :correction,
           tool_name: "correction",
           context: %{what_was_wrong: wrong, what_is_right: right}
         }) do
      {:ok, obs} ->
        append_to_ets(obs)

        Consolidator.upsert(%{
          description: "Correction: #{String.slice(wrong, 0, 80)}",
          trigger: "correction:#{trigger_key(wrong)}",
          response: right,
          category: "correction",
          tags: "correction,user_feedback"
        })

      {:error, reason} ->
        Logger.warning("[Memory.Learning] bad correction: #{reason}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:error, tool_name, error_message, context}, state) do
    {category, subcategory, suggestion} = VIGIL.classify(error_message)

    case Observation.new(%{
           type: :failure,
           tool_name: tool_name,
           error_message: error_message,
           context:
             Map.merge(context, %{
               vigil_category: category,
               vigil_subcategory: subcategory
             })
         }) do
      {:ok, obs} ->
        append_to_ets(obs)
        capture_error_pattern(tool_name, category, subcategory, suggestion)

      {:error, reason} ->
        Logger.warning("[Memory.Learning] bad error observation: #{reason}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:patterns, _from, state) do
    {:reply, {:ok, Consolidator.load_all()}, state}
  end

  @impl true
  def handle_call(:solutions, _from, state) do
    {:reply, {:ok, Consolidator.load_solutions()}, state}
  end

  @impl true
  def handle_call(:consolidate, _from, state) do
    {report, state} = run_consolidation(:full, state)
    {:reply, {:ok, report}, state}
  end

  @impl true
  def handle_call(:metrics, _from, state) do
    {:reply,
     {:ok,
      %{
        interaction_count: state.interaction_count,
        consolidation_count: state.consolidation_count,
        last_consolidation: state.last_consolidation,
        ets_observations: ets_size()
      }}, state}
  end

  # ---------------------------------------------------------------------------
  # SICA Phase 1: SEE/OBSERVE
  # ---------------------------------------------------------------------------

  defp do_observe(interaction, state) do
    case Observation.new(interaction) do
      {:ok, obs} ->
        append_to_ets(obs)
        new_count = state.interaction_count + 1
        state = %{state | interaction_count: new_count}

        # Phase 2: INTROSPECT failures inline
        if obs.type == :failure and is_binary(obs.error_message) do
          {cat, sub, suggestion} = VIGIL.classify(obs.error_message)
          capture_error_pattern(obs.tool_name, cat, sub, suggestion)
        end

        # Phase 3: CAPTURE success patterns
        if obs.type == :success do
          Consolidator.upsert(%{
            description: "Tool #{obs.tool_name} succeeded",
            trigger: "success:#{obs.tool_name}",
            response: "continue",
            category: "success",
            tags: "success,#{obs.tool_name}"
          })
        end

        # Phase 4: ADAPT — trigger consolidation on schedule
        cond do
          rem(new_count, @full_every) == 0 ->
            {_report, state} = run_consolidation(:full, state)
            state

          rem(new_count, @incremental_every) == 0 ->
            {_report, state} = run_consolidation(:incremental, state)
            state

          true ->
            state
        end

      {:error, reason} ->
        Logger.debug("[Memory.Learning] observe skip: #{reason}")
        state
    end
  end

  # ---------------------------------------------------------------------------
  # SICA Phase 3: CAPTURE helpers
  # ---------------------------------------------------------------------------

  defp capture_error_pattern(tool_name, category, subcategory, suggestion) do
    Consolidator.upsert(%{
      description: "#{category}/#{subcategory} in #{tool_name}",
      trigger: "error:#{tool_name}:#{subcategory}",
      response: suggestion,
      category: to_string(category),
      tags: "error,#{category},#{subcategory}"
    })
  end

  # ---------------------------------------------------------------------------
  # SICA Phase 4: ADAPT — consolidation
  # ---------------------------------------------------------------------------

  defp run_consolidation(mode, state) do
    report =
      case mode do
        :incremental -> Consolidator.incremental()
        :full -> Consolidator.full()
      end

    Logger.debug("[Memory.Learning] #{mode} consolidation: #{inspect(report)}")

    state = %{
      state
      | consolidation_count: state.consolidation_count + 1,
        last_consolidation: DateTime.utc_now()
    }

    {report, state}
  end

  # ---------------------------------------------------------------------------
  # ETS working memory
  # ---------------------------------------------------------------------------

  defp create_ets_table do
    try do
      :ets.new(@ets_table, [:named_table, :ordered_set, :public])
    rescue
      ArgumentError -> :already_exists
    end
  end

  defp append_to_ets(%Observation{} = obs) do
    key = System.monotonic_time(:nanosecond)

    try do
      :ets.insert(@ets_table, {key, obs})
      trim_ets_if_needed()
    rescue
      ArgumentError -> :ok
    end
  end

  defp trim_ets_if_needed do
    try do
      size = :ets.info(@ets_table, :size)

      if size > @max_observations do
        excess = size - @max_observations
        trim_oldest(:ets.first(@ets_table), excess)
      end
    rescue
      ArgumentError -> :ok
    end
  end

  defp trim_oldest(:"$end_of_table", _n), do: :ok
  defp trim_oldest(_key, 0), do: :ok

  defp trim_oldest(key, n) do
    next = :ets.next(@ets_table, key)
    :ets.delete(@ets_table, key)
    trim_oldest(next, n - 1)
  rescue
    ArgumentError -> :ok
  end

  defp ets_size do
    try do
      :ets.info(@ets_table, :size)
    rescue
      ArgumentError -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp trigger_key(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w]/, "_")
    |> String.slice(0, 40)
  end
end
