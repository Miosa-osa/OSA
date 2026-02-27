defmodule OptimalSystemAgent.Agent.Learning do
  @moduledoc """
  Self-learning engine based on SICA, VIGIL, and Mem0 patterns.

  Continuous improvement loop:
    OBSERVE  → Capture every tool interaction, error, user correction
    REFLECT  → Identify patterns across recent interactions
    PROPOSE  → Generate new patterns/skills when repetition detected
    TEST     → Validate proposed patterns against past data
    INTEGRATE → Merge validated patterns into long-term memory

  Three-tier memory:
    Working  → ETS, 15min TTL, fast access
    Episodic → JSONL files, 30-day retention
    Semantic → MEMORY.md, permanent knowledge

  Consolidation triggers:
    - Every 5 interactions (incremental)
    - Every 50 interactions (full consolidation)
    - On session end (cleanup)
    - On user correction (immediate capture)

  Based on: OSA Agent v3.3 learning engine (SICA v4.0)
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @consolidation_interval 5
  @full_consolidation_interval 50
  # 15 minutes in ms
  @working_memory_ttl 900_000
  @max_episodes 1000
  # occurrences before a pattern is saved
  @pattern_threshold 3
  # occurrences before auto-generating a skill
  @skill_generation_threshold 5

  defstruct interaction_count: 0,
            # ETS table ref
            working_memory: %{},
            # recent episodes (capped)
            episodes: [],
            # detected patterns {key => count}
            patterns: %{},
            # known solutions {error_type => fix}
            solutions: %{},
            metrics: %{
              total_interactions: 0,
              patterns_captured: 0,
              skills_generated: 0,
              errors_recovered: 0,
              consolidations: 0
            }

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a tool interaction for learning."
  @spec observe(map()) :: :ok
  def observe(interaction) do
    GenServer.cast(__MODULE__, {:observe, interaction})
  end

  @doc "Record a user correction (immediate learning)."
  @spec correction(String.t(), String.t()) :: :ok
  def correction(what_was_wrong, what_is_right) do
    GenServer.cast(__MODULE__, {:correction, what_was_wrong, what_is_right})
  end

  @doc "Record an error for VIGIL recovery."
  @spec error(String.t(), String.t(), String.t()) :: :ok
  def error(tool_name, error_message, context) do
    GenServer.cast(__MODULE__, {:error, tool_name, error_message, context})
  end

  @doc "Get current learning metrics."
  @spec metrics() :: map()
  def metrics do
    GenServer.call(__MODULE__, :metrics)
  end

  @doc "Get detected patterns."
  @spec patterns() :: map()
  def patterns do
    GenServer.call(__MODULE__, :patterns)
  end

  @doc "Get known solutions."
  @spec solutions() :: map()
  def solutions do
    GenServer.call(__MODULE__, :solutions)
  end

  @doc "Force a consolidation cycle."
  @spec consolidate() :: :ok
  def consolidate do
    GenServer.cast(__MODULE__, :consolidate)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Create working memory ETS table
    table = :ets.new(:learning_working_memory, [:set, :public])

    # Subscribe to relevant events
    subscribe_to_events()

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_working_memory, @working_memory_ttl)

    state = %__MODULE__{working_memory: table}

    # Load persisted patterns and solutions
    state = load_persisted(state)

    Logger.info(
      "[Learning] SICA engine started (patterns: #{map_size(state.patterns)}, solutions: #{map_size(state.solutions)})"
    )

    {:ok, state}
  end

  # ── OBSERVE: Record Interactions ──────────────────────────────────

  @impl true
  def handle_cast({:observe, interaction}, state) do
    episode = %{
      timestamp: DateTime.utc_now(),
      type: :tool_use,
      tool_name: interaction[:tool_name],
      duration_ms: interaction[:duration_ms],
      success: interaction[:success] != false,
      result_length: interaction[:result_length] || 0,
      context: interaction[:context]
    }

    # Store in working memory (ETS)
    key = "ep_#{state.interaction_count}"
    :ets.insert(state.working_memory, {key, episode, System.monotonic_time(:millisecond)})

    # Add to episode list (capped)
    episodes = [episode | state.episodes] |> Enum.take(@max_episodes)

    state = %{
      state
      | interaction_count: state.interaction_count + 1,
        episodes: episodes,
        metrics: %{state.metrics | total_interactions: state.metrics.total_interactions + 1}
    }

    # REFLECT: Check if it's time to consolidate
    state =
      cond do
        rem(state.interaction_count, @full_consolidation_interval) == 0 ->
          full_consolidation(state)

        rem(state.interaction_count, @consolidation_interval) == 0 ->
          incremental_consolidation(state)

        true ->
          state
      end

    {:noreply, state}
  end

  # ── OBSERVE: User Corrections (Immediate Learning) ──────────────

  @impl true
  def handle_cast({:correction, what_was_wrong, what_is_right}, state) do
    Logger.info(
      "[Learning] User correction captured: #{String.slice(what_was_wrong, 0, 50)} → #{String.slice(what_is_right, 0, 50)}"
    )

    # Immediately save to solutions
    key = normalize_key(what_was_wrong)

    solutions =
      Map.put(state.solutions, key, %{
        correction: what_is_right,
        timestamp: DateTime.utc_now(),
        source: :user_correction
      })

    state = %{
      state
      | solutions: solutions,
        metrics: %{state.metrics | patterns_captured: state.metrics.patterns_captured + 1}
    }

    # Persist immediately
    persist_solutions(state)

    Bus.emit(:system_event, %{
      event: :learning_correction,
      what: what_was_wrong,
      correction: what_is_right
    })

    {:noreply, state}
  end

  # ── OBSERVE: Errors (VIGIL Recovery) ──────────────────────────────

  @impl true
  def handle_cast({:error, tool_name, error_message, context}, state) do
    error_type = classify_error(error_message)

    episode = %{
      timestamp: DateTime.utc_now(),
      type: :error,
      tool_name: tool_name,
      error_type: error_type,
      error_message: String.slice(error_message, 0, 500),
      context: context
    }

    episodes = [episode | state.episodes] |> Enum.take(@max_episodes)

    # Check if we have a known solution
    case Map.get(state.solutions, error_type) do
      nil ->
        Logger.debug("[Learning] New error type: #{error_type}")

      solution ->
        Logger.info(
          "[Learning] Known solution for #{error_type}: #{inspect(solution.correction)}"
        )

        Bus.emit(:system_event, %{
          event: :learning_recovery_available,
          error_type: error_type,
          solution: solution.correction
        })
    end

    state = %{
      state
      | episodes: episodes,
        metrics: %{state.metrics | errors_recovered: state.metrics.errors_recovered + 1}
    }

    {:noreply, state}
  end

  # ── CONSOLIDATE ───────────────────────────────────────────────────

  @impl true
  def handle_cast(:consolidate, state) do
    {:noreply, full_consolidation(state)}
  end

  @impl true
  def handle_call(:metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  @impl true
  def handle_call(:patterns, _from, state) do
    {:reply, state.patterns, state}
  end

  @impl true
  def handle_call(:solutions, _from, state) do
    {:reply, state.solutions, state}
  end

  # ── Periodic Cleanup ──────────────────────────────────────────────

  @impl true
  def handle_info(:cleanup_working_memory, state) do
    # Remove old entries from working memory
    now = System.monotonic_time(:millisecond)
    cutoff = now - @working_memory_ttl

    :ets.foldl(
      fn {key, _ep, ts}, acc ->
        if ts < cutoff, do: :ets.delete(state.working_memory, key)
        acc
      end,
      :ok,
      state.working_memory
    )

    Process.send_after(self(), :cleanup_working_memory, @working_memory_ttl)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── REFLECT: Incremental Consolidation ──────────────────────────

  defp incremental_consolidation(state) do
    recent = Enum.take(state.episodes, @consolidation_interval)

    # Extract tool usage patterns
    tool_patterns =
      recent
      |> Enum.filter(&(&1.type == :tool_use))
      |> Enum.group_by(& &1.tool_name)
      |> Enum.map(fn {tool, uses} ->
        avg_duration =
          uses
          |> Enum.map(&(&1.duration_ms || 0))
          |> then(fn ds ->
            if ds == [], do: 0, else: div(Enum.sum(ds), length(ds))
          end)

        success_rate = Enum.count(uses, & &1.success) / max(length(uses), 1)

        {"tool:#{tool}",
         %{count: length(uses), avg_duration: avg_duration, success_rate: success_rate}}
      end)

    # Merge into patterns
    patterns =
      Enum.reduce(tool_patterns, state.patterns, fn {key, info}, acc ->
        existing = Map.get(acc, key, %{count: 0})

        Map.put(acc, key, %{
          count: existing.count + info.count,
          avg_duration: info.avg_duration,
          success_rate: info.success_rate,
          last_seen: DateTime.utc_now()
        })
      end)

    # Check for skill generation candidates
    state = check_skill_generation(patterns, state)

    %{
      state
      | patterns: patterns,
        metrics: %{state.metrics | consolidations: state.metrics.consolidations + 1}
    }
  end

  # ── REFLECT: Full Consolidation ─────────────────────────────────

  defp full_consolidation(state) do
    Logger.info(
      "[Learning] Full consolidation (#{length(state.episodes)} episodes, #{map_size(state.patterns)} patterns)"
    )

    # 1. Consolidate error patterns into solutions
    error_episodes = Enum.filter(state.episodes, &(&1.type == :error))
    error_groups = Enum.group_by(error_episodes, & &1.error_type)

    solutions =
      Enum.reduce(error_groups, state.solutions, fn {error_type, errors}, acc ->
        if length(errors) >= @pattern_threshold and not Map.has_key?(acc, error_type) do
          # Auto-generate a solution entry from repeated errors
          Map.put(acc, error_type, %{
            correction: "Recurring error (#{length(errors)}x). Check: #{hd(errors).context}",
            timestamp: DateTime.utc_now(),
            source: :auto_detected
          })
        else
          acc
        end
      end)

    # 2. Prune old patterns (not seen in 100+ interactions)
    patterns =
      state.patterns
      |> Enum.filter(fn {_key, info} ->
        info.count >= 2 or
          DateTime.diff(DateTime.utc_now(), info[:last_seen] || DateTime.utc_now(), :hour) < 24
      end)
      |> Map.new()

    # 3. Persist
    state = %{
      state
      | patterns: patterns,
        solutions: solutions,
        metrics: %{
          state.metrics
          | consolidations: state.metrics.consolidations + 1,
            patterns_captured: map_size(patterns)
        }
    }

    persist_patterns(state)
    persist_solutions(state)

    Bus.emit(:system_event, %{
      event: :learning_consolidation,
      patterns: map_size(patterns),
      solutions: map_size(solutions),
      episodes: length(state.episodes)
    })

    state
  end

  # ── PROPOSE: Skill Generation ─────────────────────────────────────

  defp check_skill_generation(patterns, state) do
    candidates =
      patterns
      |> Enum.filter(fn {_key, info} -> info.count >= @skill_generation_threshold end)
      |> Enum.reject(fn {key, _info} -> String.starts_with?(key, "tool:") end)

    if candidates != [] do
      Logger.info("[Learning] #{length(candidates)} skill generation candidates detected")

      Bus.emit(:system_event, %{
        event: :learning_skill_candidates,
        count: length(candidates),
        candidates: Enum.map(candidates, fn {key, _} -> key end)
      })

      %{
        state
        | metrics: %{
            state.metrics
            | skills_generated: state.metrics.skills_generated + length(candidates)
          }
      }
    else
      state
    end
  end

  # ── Error Classification (VIGIL) ──────────────────────────────────

  @error_taxonomy [
    {~r/file.*not found|no such file/i, "file_not_found"},
    {~r/permission denied/i, "permission_denied"},
    {~r/syntax error/i, "syntax_error"},
    {~r/import.*error|module.*not found/i, "import_error"},
    {~r/type.*error|expected.*got/i, "type_error"},
    {~r/network|connection.*refused/i, "network_error"},
    {~r/out of memory|memory/i, "memory_error"},
    {~r/timeout/i, "timeout_error"},
    {~r/compilation.*error|compile.*fail/i, "compilation_error"},
    {~r/test.*fail/i, "test_failure"}
  ]

  defp classify_error(error_message) do
    Enum.find_value(@error_taxonomy, "unknown_error", fn {pattern, type} ->
      if Regex.match?(pattern, error_message), do: type
    end)
  end

  # ── Event Subscriptions ─────────────────────────────────────────

  defp subscribe_to_events do
    Bus.register_handler(:tool_call, fn payload ->
      case payload do
        %{name: name, phase: :end, duration_ms: ms} ->
          observe(%{
            tool_name: name,
            duration_ms: ms,
            success: true
          })

        _ ->
          :ok
      end
    end)

    Bus.register_handler(:system_event, fn payload ->
      case payload do
        %{event: :tool_learning} ->
          observe(%{
            tool_name: payload[:tool_name],
            duration_ms: payload[:duration_ms],
            result_length: payload[:result_length],
            success: payload[:success]
          })

        %{event: :error_detected} ->
          error("unknown", payload[:error] || "", "")

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  # ── Persistence ───────────────────────────────────────────────────

  defp learning_dir do
    dir = Path.expand("~/.osa/learning")
    File.mkdir_p!(dir)
    dir
  end

  defp persist_patterns(state) do
    path = Path.join(learning_dir(), "patterns.json")

    data =
      Enum.map(state.patterns, fn {key, info} ->
        %{
          key: key,
          count: info.count,
          last_seen: to_string(info[:last_seen] || DateTime.utc_now())
        }
      end)

    File.write!(path, Jason.encode!(data, pretty: true))
  rescue
    e -> Logger.warning("[Learning] Failed to persist patterns: #{Exception.message(e)}")
  end

  defp persist_solutions(state) do
    path = Path.join(learning_dir(), "solutions.json")

    data =
      Enum.map(state.solutions, fn {key, info} ->
        %{key: key, correction: info.correction, source: to_string(info.source)}
      end)

    File.write!(path, Jason.encode!(data, pretty: true))
  rescue
    e -> Logger.warning("[Learning] Failed to persist solutions: #{Exception.message(e)}")
  end

  defp load_persisted(state) do
    patterns = load_json("patterns.json", [])
    solutions = load_json("solutions.json", [])

    patterns_map =
      Enum.reduce(patterns, %{}, fn entry, acc ->
        Map.put(acc, entry["key"], %{
          count: entry["count"] || 0,
          last_seen: DateTime.utc_now()
        })
      end)

    solutions_map =
      Enum.reduce(solutions, %{}, fn entry, acc ->
        Map.put(acc, entry["key"], %{
          correction: entry["correction"],
          source: String.to_atom(entry["source"] || "loaded"),
          timestamp: DateTime.utc_now()
        })
      end)

    %{state | patterns: patterns_map, solutions: solutions_map}
  end

  defp load_json(filename, default) do
    path = Path.join(learning_dir(), filename)

    if File.exists?(path) do
      case File.read!(path) |> Jason.decode() do
        {:ok, data} when is_list(data) -> data
        _ -> default
      end
    else
      default
    end
  rescue
    _ -> default
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp normalize_key(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.take(5)
    |> Enum.join("_")
  end
end
