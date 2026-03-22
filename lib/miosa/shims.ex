# Miosa* shim modules
#
# The extracted miosa_* packages do not exist as path deps in this repository.
# Instead, the actual implementations live inside OptimalSystemAgent itself.
# These shim modules alias the real implementations so that:
#   1. Code that calls MiosaXxx.Foo.bar() compiles and dispatches correctly.
#   2. OSA modules that declare @behaviour MiosaXxx.Behaviour compile.
#   3. Stub modules are provided for packages that have no OSA equivalent yet
#      (MiosaKnowledge, pure behaviour/struct types, etc.).
#
# Planned modules (guarded with Code.ensure_loaded?/1):
#   - MiosaMemory.Injector  → OptimalSystemAgent.Agent.Memory.Injector  (not yet implemented)
#   - MiosaMemory.Taxonomy  → OptimalSystemAgent.Agent.Memory.Taxonomy  (not yet implemented)
#   - MiosaMemory.Learning  → OptimalSystemAgent.Agent.Learning          (not yet implemented)
#
# Each guarded shim provides a graceful fallback so the supervision tree starts
# cleanly. When the real module is added, the guard condition flips automatically
# at the next compile and all calls are forwarded to the real implementation.
#
# File: lib/miosa/shims.ex

# ---------------------------------------------------------------------------
# MiosaTools
# ---------------------------------------------------------------------------

defmodule MiosaTools.Behaviour do
  @moduledoc """
  Behaviour contract for OSA tools.

  Any module that implements this behaviour becomes a registered tool in
  `OptimalSystemAgent.Tools.Registry`.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map()) :: {:ok, any()} | {:error, String.t()}
  @callback safety() :: :read_only | :write_safe | :write_destructive | :terminal
  @callback available?() :: boolean()

  defmacro __using__(_opts) do
    quote do
      @behaviour MiosaTools.Behaviour
    end
  end
end

defmodule MiosaTools.Instruction do
  @moduledoc """
  Normalized tool instruction struct.

  Represents a validated tool call with its name, parameters, and execution context.
  Used by the tool pipeline to normalize various input formats (string, tuple, struct)
  into a consistent representation.
  """

  defstruct tool: "", params: %{}, context: %{}

  @type t :: %__MODULE__{
          tool: String.t(),
          params: map(),
          context: map()
        }

  @doc "Normalize various input formats into an `%Instruction{}`."
  @spec normalize(term()) :: {:ok, t()} | {:error, String.t()}
  def normalize(%__MODULE__{tool: ""}) do
    {:error, "Tool name cannot be empty"}
  end

  def normalize(%__MODULE__{} = inst), do: {:ok, inst}

  def normalize(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "" do
      {:error, "Tool name cannot be empty"}
    else
      {:ok, %__MODULE__{tool: trimmed, params: %{}, context: %{}}}
    end
  end

  def normalize({tool, params}) when is_binary(tool) and is_map(params) do
    {:ok, %__MODULE__{tool: tool, params: params, context: %{}}}
  end

  def normalize({tool, params, context})
      when is_binary(tool) and is_map(params) and is_map(context) do
    {:ok, %__MODULE__{tool: tool, params: params, context: context}}
  end

  def normalize({_tool, _params}) do
    {:error, "Cannot normalize: params must be a map"}
  end

  def normalize({_tool, _params, _context}) do
    {:error, "Cannot normalize: params and context must be maps"}
  end

  def normalize(other) do
    {:error, "Cannot normalize #{inspect(other)} into an Instruction"}
  end

  @doc "Like `normalize/1` but raises on invalid input."
  @spec normalize!(term()) :: t()
  def normalize!(input) do
    case normalize(input) do
      {:ok, inst} -> inst
      {:error, msg} -> raise ArgumentError, msg
    end
  end

  @doc "Merge additional params into an existing instruction."
  @spec merge_params(t(), map()) :: t()
  def merge_params(%__MODULE__{} = inst, new_params) when is_map(new_params) do
    %{inst | params: Map.merge(inst.params, new_params)}
  end
end

# ---------------------------------------------------------------------------
# MiosaLLM
# ---------------------------------------------------------------------------

defmodule MiosaLLM.HealthChecker do
  @moduledoc "Shim — delegates to OptimalSystemAgent.Providers.HealthChecker."

  defdelegate start_link(opts \\ []), to: OptimalSystemAgent.Providers.HealthChecker
  defdelegate child_spec(opts), to: OptimalSystemAgent.Providers.HealthChecker
  defdelegate record_success(provider), to: OptimalSystemAgent.Providers.HealthChecker
  defdelegate record_failure(provider, reason), to: OptimalSystemAgent.Providers.HealthChecker
  defdelegate record_rate_limited(provider, retry_after_seconds \\ nil),
    to: OptimalSystemAgent.Providers.HealthChecker
  defdelegate is_available?(provider), to: OptimalSystemAgent.Providers.HealthChecker
  defdelegate state(), to: OptimalSystemAgent.Providers.HealthChecker
end

# ---------------------------------------------------------------------------
# MiosaProviders
# ---------------------------------------------------------------------------

defmodule MiosaProviders.Registry do
  @moduledoc "Shim — delegates to OptimalSystemAgent.Providers.Registry."

  defdelegate start_link(opts \\ []), to: OptimalSystemAgent.Providers.Registry
  defdelegate child_spec(opts), to: OptimalSystemAgent.Providers.Registry
  defdelegate chat(messages, opts \\ []), to: OptimalSystemAgent.Providers.Registry
  defdelegate chat_stream(messages, callback, opts \\ []),
    to: OptimalSystemAgent.Providers.Registry
  defdelegate chat_with_fallback(messages, chain, opts \\ []),
    to: OptimalSystemAgent.Providers.Registry
  defdelegate list_providers(), to: OptimalSystemAgent.Providers.Registry
  defdelegate provider_info(provider), to: OptimalSystemAgent.Providers.Registry
  defdelegate context_window(model), to: OptimalSystemAgent.Providers.Registry
  defdelegate provider_configured?(provider), to: OptimalSystemAgent.Providers.Registry
  defdelegate register_provider(name, module), to: OptimalSystemAgent.Providers.Registry
end

defmodule MiosaProviders.Ollama do
  @moduledoc "Shim — delegates to OptimalSystemAgent.Providers.Ollama."

  defdelegate auto_detect_model(), to: OptimalSystemAgent.Providers.Ollama
  defdelegate reachable?(), to: OptimalSystemAgent.Providers.Ollama
  defdelegate list_models(url \\ nil), to: OptimalSystemAgent.Providers.Ollama
  defdelegate model_supports_tools?(model_name), to: OptimalSystemAgent.Providers.Ollama
  defdelegate thinking_model?(model_name), to: OptimalSystemAgent.Providers.Ollama
  defdelegate chat(messages, opts \\ []), to: OptimalSystemAgent.Providers.Ollama
  defdelegate chat_stream(messages, callback, opts \\ []),
    to: OptimalSystemAgent.Providers.Ollama
  defdelegate pick_best_model(models), to: OptimalSystemAgent.Providers.Ollama
end

# ---------------------------------------------------------------------------
# MiosaSignal
# ---------------------------------------------------------------------------

defmodule MiosaSignal.Event do
  @moduledoc "Shim — re-exports OptimalSystemAgent.Events.Event struct and delegates."

  # Re-export the struct so that %MiosaSignal.Event{} pattern matches compile.
  defstruct [
    :id, :type, :source, :time,
    :subject, :data, :dataschema,
    :parent_id, :session_id, :correlation_id,
    :signal_mode, :signal_genre, :signal_type, :signal_format, :signal_structure, :signal_sn,
    specversion: "1.0.2",
    datacontenttype: "application/json",
    extensions: %{}
  ]

  @type t :: OptimalSystemAgent.Events.Event.t()

  defdelegate new(type, source), to: OptimalSystemAgent.Events.Event
  defdelegate new(type, source, data), to: OptimalSystemAgent.Events.Event
  defdelegate new(type, source, data, opts), to: OptimalSystemAgent.Events.Event
  defdelegate child(parent, type, source), to: OptimalSystemAgent.Events.Event
  defdelegate child(parent, type, source, data), to: OptimalSystemAgent.Events.Event
  defdelegate child(parent, type, source, data, opts), to: OptimalSystemAgent.Events.Event
  defdelegate to_map(event), to: OptimalSystemAgent.Events.Event
  defdelegate to_cloud_event(event), to: OptimalSystemAgent.Events.Event
end

defmodule MiosaSignal.CloudEvent do
  @moduledoc "Shim — re-exports OptimalSystemAgent.Protocol.CloudEvent struct and delegates."

  defstruct [
    :specversion, :type, :source, :subject, :id, :time,
    :datacontenttype, :data
  ]

  @type t :: OptimalSystemAgent.Protocol.CloudEvent.t()

  defdelegate new(attrs), to: OptimalSystemAgent.Protocol.CloudEvent
  defdelegate encode(event), to: OptimalSystemAgent.Protocol.CloudEvent
  defdelegate decode(json), to: OptimalSystemAgent.Protocol.CloudEvent
  defdelegate from_bus_event(event_map), to: OptimalSystemAgent.Protocol.CloudEvent
  defdelegate to_bus_event(event), to: OptimalSystemAgent.Protocol.CloudEvent
end

defmodule MiosaSignal.Classifier do
  @moduledoc "Shim — delegates to OptimalSystemAgent.Events.Classifier."

  @type classification :: OptimalSystemAgent.Events.Classifier.classification()

  defdelegate classify(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate auto_classify(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate sn_ratio(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate infer_mode(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate infer_genre(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate infer_type(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate infer_format(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate infer_structure(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate dimension_score(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate data_score(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate type_score(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate context_score(event), to: OptimalSystemAgent.Events.Classifier
  defdelegate code_like?(str), to: OptimalSystemAgent.Events.Classifier
end

defmodule MiosaSignal.MessageClassifier do
  @moduledoc "Signal Theory message classification result struct + classifier."

  defstruct [
    :mode, :genre, :type, :format, :weight,
    :raw, :channel, :timestamp, :confidence
  ]

  @type t :: %__MODULE__{}

  @doc "Fast ETS-cached classification."
  def classify_fast(message, channel) do
    classify_deterministic(message, channel)
  end

  @doc "Deterministic pattern-matching classification (no LLM)."
  def classify_deterministic(message, _channel) when is_binary(message) do
    msg = String.downcase(message)
    mode = cond do
      Regex.match?(~r/\b(run|execute|send|deploy|delete|trigger|sync|import|export)\b/, msg) -> :execute
      Regex.match?(~r/\b(create|generate|write|scaffold|design|build|develop|make|implement)\b/, msg) -> :build
      Regex.match?(~r/\b(analyze|report|compare|metrics|trend|dashboard|review|kpi)\b/, msg) -> :analyze
      Regex.match?(~r/\b(fix|update|migrate|backup|restore|rollback|patch|upgrade|debug)\b/, msg) -> :maintain
      true -> :assist
    end
    genre = cond do
      Regex.match?(~r/\b(please|can you|could you|do|make|create)\b/, msg) -> :direct
      Regex.match?(~r/\b(i will|i'll|let me|i can)\b/, msg) -> :commit
      Regex.match?(~r/\b(approve|reject|confirm|cancel|choose|decide)\b/, msg) -> :decide
      Regex.match?(~r/[!?]|great|thanks|thank you|sorry|frustrated/, msg) -> :express
      true -> :inform
    end
    weight = calculate_weight(message)
    {:ok, %__MODULE__{
      mode: mode, genre: genre, type: "general",
      format: :text, weight: weight, raw: message,
      channel: nil, timestamp: DateTime.utc_now(), confidence: :low
    }}
  end
  def classify_deterministic(_, _), do: {:error, :invalid_message}

  @doc "Calculate signal weight (0.0 – 1.0) based on message characteristics."
  def calculate_weight(message) when is_binary(message) do
    len = String.length(message)
    base = min(len / 500.0, 1.0)
    Float.round(base, 2)
  end
  def calculate_weight(_), do: 0.5
end

defmodule MiosaSignal.FailureModes do
  @moduledoc "Shim — delegates to OptimalSystemAgent.Events.FailureModes."

  @type failure_mode :: OptimalSystemAgent.Events.FailureModes.failure_mode()

  defdelegate detect(event), to: OptimalSystemAgent.Events.FailureModes
  defdelegate check(event, mode), to: OptimalSystemAgent.Events.FailureModes
end

# ---------------------------------------------------------------------------
# MiosaMemory
# ---------------------------------------------------------------------------

# MiosaMemory.Store — see lib/miosa/memory_store.ex for the full GenServer implementation.

defmodule MiosaMemory.Emitter do
  @moduledoc "Behaviour for memory event emission."

  @callback emit(topic :: atom() | String.t(), payload :: map()) :: :ok | {:error, term()}
end

defmodule MiosaMemory.Cortex do
  @moduledoc "Shim — delegates to OptimalSystemAgent.Agent.Cortex (the actual GenServer)."
  # Note: OptimalSystemAgent.Agent.Cortex itself delegates here, creating a loop.
  # We break the loop by implementing a minimal stub that the supervisor can start.
  # The real Cortex work is done in OptimalSystemAgent.Agent.Cortex.

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def bulletin do
    GenServer.call(__MODULE__, :bulletin)
  end

  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  def active_topics do
    GenServer.call(__MODULE__, :active_topics)
  end

  def session_summary(session_id) do
    GenServer.call(__MODULE__, {:session_summary, session_id})
  end

  def synthesis_stats do
    GenServer.call(__MODULE__, :synthesis_stats)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call(:bulletin, _from, state), do: {:reply, "", state}
  def handle_call(:refresh, _from, state), do: {:reply, :ok, state}
  def handle_call(:active_topics, _from, state), do: {:reply, [], state}
  def handle_call({:session_summary, _sid}, _from, state), do: {:reply, %{}, state}
  def handle_call(:synthesis_stats, _from, state), do: {:reply, %{}, state}
end

defmodule MiosaMemory.Episodic do
  @moduledoc """
  Shim — delegates to OptimalSystemAgent.Agent.Memory.Episodic (the real GenServer).

  This shim exists so callers using the MiosaMemory.Episodic namespace compile
  and route to the actual ETS-backed implementation.
  """

  def start_link(opts \\ []),
    do: OptimalSystemAgent.Agent.Memory.Episodic.start_link(opts)

  def child_spec(opts),
    do: OptimalSystemAgent.Agent.Memory.Episodic.child_spec(opts)

  def record(event_type, data, session_id),
    do: OptimalSystemAgent.Agent.Memory.Episodic.record(event_type, data, session_id)

  def recall(query, opts \\ []),
    do: OptimalSystemAgent.Agent.Memory.Episodic.recall(query, opts)

  def recent(session_id, limit \\ 20),
    do: OptimalSystemAgent.Agent.Memory.Episodic.recent(session_id, limit)

  def stats,
    do: OptimalSystemAgent.Agent.Memory.Episodic.stats()

  def clear_session(session_id),
    do: OptimalSystemAgent.Agent.Memory.Episodic.clear_session(session_id)

  def temporal_decay(timestamp, half_life_hours),
    do: OptimalSystemAgent.Agent.Memory.Episodic.temporal_decay(timestamp, half_life_hours)
end

defmodule MiosaMemory.Injector do
  @moduledoc """
  Shim for OptimalSystemAgent.Agent.Memory.Injector.

  The target module is planned but not yet implemented. All functions degrade
  gracefully so callers can proceed without injection support.
  """

  @type injection_context :: map()

  if Code.ensure_loaded?(OptimalSystemAgent.Agent.Memory.Injector) do
    defdelegate inject_relevant(entries, context),
      to: OptimalSystemAgent.Agent.Memory.Injector
    defdelegate format_for_prompt(entries), to: OptimalSystemAgent.Agent.Memory.Injector
  else
    @doc "Returns entries unchanged when the Injector module is unavailable."
    def inject_relevant(entries, _context), do: entries

    @doc "Returns an empty string when the Injector module is unavailable."
    def format_for_prompt(_entries), do: ""
  end
end

defmodule MiosaMemory.Taxonomy do
  @moduledoc """
  Shim for OptimalSystemAgent.Agent.Memory.Taxonomy.

  The target module is planned but not yet implemented. All functions degrade
  gracefully so callers can proceed without taxonomy support.
  """

  @type t :: map()
  @type category :: String.t()
  @type scope :: String.t()

  if Code.ensure_loaded?(OptimalSystemAgent.Agent.Memory.Taxonomy) do
    defdelegate new(content, opts \\ []), to: OptimalSystemAgent.Agent.Memory.Taxonomy
    defdelegate categorize(content), to: OptimalSystemAgent.Agent.Memory.Taxonomy
    defdelegate filter_by(entries, filters), to: OptimalSystemAgent.Agent.Memory.Taxonomy
    defdelegate categories(), to: OptimalSystemAgent.Agent.Memory.Taxonomy
    defdelegate scopes(), to: OptimalSystemAgent.Agent.Memory.Taxonomy
    defdelegate touch(entry), to: OptimalSystemAgent.Agent.Memory.Taxonomy
    defdelegate valid_category?(cat), to: OptimalSystemAgent.Agent.Memory.Taxonomy
    defdelegate valid_scope?(scope), to: OptimalSystemAgent.Agent.Memory.Taxonomy
  else
    def new(content, opts \\ []), do: %{content: content, opts: opts, category: "general", scope: "session"}
    def categorize(_content), do: "general"
    def filter_by(entries, _filters), do: entries
    def categories, do: ["general"]
    def scopes, do: ["session"]
    def touch(entry), do: entry
    def valid_category?(_cat), do: true
    def valid_scope?(_scope), do: true
  end
end

defmodule MiosaMemory.Learning do
  @moduledoc """
  Shim for OptimalSystemAgent.Agent.Learning.

  The target GenServer is planned but not yet implemented. When the real module
  is available, all calls are forwarded to it. Until then, every function
  degrades gracefully with no-op or empty-collection returns so the supervision
  tree starts without errors.
  """

  if Code.ensure_loaded?(OptimalSystemAgent.Agent.Learning) do
    def start_link(opts \\ []),
      do: OptimalSystemAgent.Agent.Learning.start_link(opts)

    def child_spec(opts),
      do: OptimalSystemAgent.Agent.Learning.child_spec(opts)

    def observe(interaction),
      do: OptimalSystemAgent.Agent.Learning.observe(interaction)

    def correction(what_was_wrong, what_is_right),
      do: OptimalSystemAgent.Agent.Learning.correction(what_was_wrong, what_is_right)

    def error(tool_name, error_message, context),
      do: OptimalSystemAgent.Agent.Learning.error(tool_name, error_message, context)

    def metrics, do: OptimalSystemAgent.Agent.Learning.metrics()
    def patterns, do: OptimalSystemAgent.Agent.Learning.patterns()
    def solutions, do: OptimalSystemAgent.Agent.Learning.solutions()
    def consolidate, do: OptimalSystemAgent.Agent.Learning.consolidate()
  else
    def start_link(_opts \\ []), do: :ignore
    def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :worker}
    def observe(_interaction), do: :ok
    def correction(_what_was_wrong, _what_is_right), do: :ok
    def error(_tool_name, _error_message, _context), do: :ok
    def metrics, do: %{}
    def patterns, do: []
    def solutions, do: []
    def consolidate, do: :ok
  end
end

defmodule MiosaMemory.Parser do
  @moduledoc "Stub parser — MiosaMemory.Store handles parsing internally."

  @doc "Parse memory file content into entry maps."
  def parse(content) when is_binary(content) do
    content
    |> String.split("\n## ", trim: true)
    |> Enum.map(fn chunk ->
      [header | lines] = String.split(chunk, "\n", parts: 2)
      %{header: String.trim(header), content: Enum.join(lines, "\n") |> String.trim()}
    end)
  end

  @stop_words MapSet.new(~w(
    the and for are but not you all any can had her was one our out day been have
    from this that with what when will more about which them than been would make
    like time just know take people into year your good some could over such after
    come made find back only first great even give most those down should well
    being work through where much other also life between know years hand high
    because large turn each long next look state want head around move both
    think still might school world kind keep never really need does going right
    used every last very just said same tell call before mean also actually thing
    many then those however these while most only must since well still under
    again too own part here there where help using really trying getting doing
    went got let its use way may new now old see try run put set did get how
    has him his she her its who why yes yet able
  ))

  @doc "Extract keywords from text with stop-word filtering."
  def extract_keywords(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/\W+/, trim: true)
    |> Enum.reject(fn word -> MapSet.member?(@stop_words, word) end)
    |> Enum.filter(fn word -> String.length(word) >= 3 end)
    |> Enum.reject(fn word -> Regex.match?(~r/^\d+$/, word) end)
    |> Enum.uniq()
  end
end

defmodule MiosaMemory.Index do
  @moduledoc "Stub index — MiosaMemory.Store manages the ETS index internally."

  @doc "Extract keywords from a message for index lookup."
  def extract_keywords(message) when is_binary(message) do
    MiosaMemory.Parser.extract_keywords(message)
  end

  def extract_keywords(_), do: []
end

# ---------------------------------------------------------------------------
# MiosaBudget
# ---------------------------------------------------------------------------

defmodule MiosaBudget.Emitter do
  @moduledoc "Behaviour for budget event emission."

  @callback emit(topic :: atom() | String.t(), payload :: map()) :: :ok | {:error, term()}
end

defmodule MiosaBudget.Budget do
  @moduledoc """
  Budget GenServer — token/cost tracking with daily and monthly limits.

  This is the actual implementation (not a shim). OSA has no pre-existing
  Budget GenServer, so this module provides one that satisfies all call sites.
  """
  use GenServer
  require Logger

  @daily_default_usd   50.0
  @monthly_default_usd 200.0

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def check_budget do
    GenServer.call(__MODULE__, :check_budget)
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  def record_cost(provider, model, tokens_in, tokens_out, session_id) do
    GenServer.cast(__MODULE__, {:record_cost, provider, model, tokens_in, tokens_out, session_id})
  end

  def calculate_cost(_provider, tokens_in, tokens_out) do
    # Conservative flat rate: $0.000003 per token (~$3/M blended)
    (tokens_in + tokens_out) * 0.000003
  end

  def reset_daily do
    GenServer.cast(__MODULE__, :reset_daily)
  end

  def reset_monthly do
    GenServer.cast(__MODULE__, :reset_monthly)
  end

  # GenServer callbacks

  @impl true
  def init(:ok) do
    state = %{
      daily_spent: 0.0,
      monthly_spent: 0.0,
      daily_limit: Application.get_env(:optimal_system_agent, :daily_budget_usd, @daily_default_usd),
      monthly_limit: Application.get_env(:optimal_system_agent, :monthly_budget_usd, @monthly_default_usd),
      entries: [],
      daily_reset_at: tomorrow_midnight(),
      monthly_reset_at: next_month_midnight()
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:check_budget, _from, state) do
    state = maybe_reset(state)
    daily_remaining = max(0.0, state.daily_limit - state.daily_spent)
    monthly_remaining = max(0.0, state.monthly_limit - state.monthly_spent)

    result =
      cond do
        state.daily_spent >= state.daily_limit -> {:over_limit, :daily}
        state.monthly_spent >= state.monthly_limit -> {:over_limit, :monthly}
        true -> {:ok, %{daily_remaining: daily_remaining, monthly_remaining: monthly_remaining}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    state = maybe_reset(state)
    status = %{
      daily_limit: state.daily_limit,
      monthly_limit: state.monthly_limit,
      daily_spent: state.daily_spent,
      monthly_spent: state.monthly_spent,
      daily_remaining: max(0.0, state.daily_limit - state.daily_spent),
      monthly_remaining: max(0.0, state.monthly_limit - state.monthly_spent),
      daily_reset_at: state.daily_reset_at,
      monthly_reset_at: state.monthly_reset_at,
      ledger_entries: length(state.entries)
    }
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:record_cost, provider, model, tokens_in, tokens_out, session_id}, state) do
    cost = calculate_cost(provider, tokens_in, tokens_out)
    entry = %{
      provider: provider, model: model,
      tokens_in: tokens_in, tokens_out: tokens_out,
      cost: cost, session_id: session_id,
      recorded_at: DateTime.utc_now()
    }
    state = %{state |
      daily_spent: state.daily_spent + cost,
      monthly_spent: state.monthly_spent + cost,
      entries: Enum.take([entry | state.entries], 10_000)
    }
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset_daily, state) do
    {:noreply, %{state | daily_spent: 0.0, daily_reset_at: tomorrow_midnight()}}
  end

  @impl true
  def handle_cast(:reset_monthly, state) do
    {:noreply, %{state | monthly_spent: 0.0, monthly_reset_at: next_month_midnight()}}
  end

  defp maybe_reset(state) do
    now = DateTime.utc_now()
    state
    |> maybe_reset_daily(now)
    |> maybe_reset_monthly(now)
  end

  defp maybe_reset_daily(state, now) do
    if DateTime.compare(now, state.daily_reset_at) == :gt do
      %{state | daily_spent: 0.0, daily_reset_at: tomorrow_midnight()}
    else
      state
    end
  end

  defp maybe_reset_monthly(state, now) do
    if DateTime.compare(now, state.monthly_reset_at) == :gt do
      %{state | monthly_spent: 0.0, monthly_reset_at: next_month_midnight()}
    else
      state
    end
  end

  defp tomorrow_midnight do
    Date.utc_today()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(0, 0, 0), "Etc/UTC")
  end

  defp next_month_midnight do
    today = Date.utc_today()
    {year, month} = if today.month == 12, do: {today.year + 1, 1}, else: {today.year, today.month + 1}
    Date.new!(year, month, 1)
    |> DateTime.new!(Time.new!(0, 0, 0), "Etc/UTC")
  end
end

defmodule MiosaBudget.Treasury do
  @moduledoc "Stub Treasury — budget reserve/release accounting."

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def balance, do: GenServer.call(__MODULE__, :balance)
  def deposit(amount, reason), do: GenServer.cast(__MODULE__, {:deposit, amount, reason})
  def withdraw(amount, reason), do: GenServer.cast(__MODULE__, {:withdraw, amount, reason})
  def reserve(amount, reason), do: GenServer.cast(__MODULE__, {:reserve, amount, reason})
  def release(amount, reason), do: GenServer.cast(__MODULE__, {:release, amount, reason})
  def audit_log, do: GenServer.call(__MODULE__, :audit_log)

  @impl true
  def init(:ok), do: {:ok, %{balance: 0.0, reserved: 0.0, log: []}}
  @impl true
  def handle_call(:balance, _from, s), do: {:reply, {:ok, %{balance: s.balance, reserved: s.reserved}}, s}
  def handle_call(:audit_log, _from, s), do: {:reply, {:ok, s.log}, s}
  @impl true
  def handle_cast({:deposit, amt, reason}, s) do
    {:noreply, %{s | balance: s.balance + amt, log: [{:deposit, amt, reason} | s.log]}}
  end
  def handle_cast({:withdraw, amt, reason}, s) do
    {:noreply, %{s | balance: s.balance - amt, log: [{:withdraw, amt, reason} | s.log]}}
  end
  def handle_cast({:reserve, amt, reason}, s) do
    {:noreply, %{s | reserved: s.reserved + amt, log: [{:reserve, amt, reason} | s.log]}}
  end
  def handle_cast({:release, amt, reason}, s) do
    {:noreply, %{s | reserved: s.reserved - amt, log: [{:release, amt, reason} | s.log]}}
  end
end

# ---------------------------------------------------------------------------
# MiosaKnowledge  (stubs — no OSA equivalent)
# ---------------------------------------------------------------------------

defmodule MiosaKnowledge.Registry do
  @moduledoc "Stub — knowledge store registry."
  def lookup(_name), do: {:error, :not_implemented}
end

defmodule MiosaKnowledge.Backend.ETS do
  @moduledoc "Stub ETS backend."
  def open(_name, _opts \\ []), do: {:ok, :ets_stub}
  def close(_ref), do: :ok
end

defmodule MiosaKnowledge.Backend.Mnesia do
  @moduledoc "Stub Mnesia backend."
  def open(_name, _opts \\ []), do: {:ok, :mnesia_stub}
  def close(_ref), do: :ok
end

defmodule MiosaKnowledge.Context do
  @moduledoc "Stub — knowledge context for agent prompts."
  def for_agent(_store_ref, _opts \\ []), do: %{}
  def to_prompt(_ctx), do: ""
end

defmodule MiosaKnowledge.Reasoner do
  @moduledoc "Stub — forward-chaining reasoner."
  def materialize(_store_ref, _rules \\ []), do: {:ok, []}
end

defmodule MiosaKnowledge.Store do
  @moduledoc "Stub — knowledge store supervisor entry."
  def start_link(_opts \\ []), do: {:ok, self()}
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end
end

defmodule MiosaKnowledge do
  @moduledoc "Stub — top-level knowledge graph API."
  def open(_name, _opts \\ []), do: {:ok, :stub}
  def assert(_store, _triple), do: {:ok, 1}
  def assert_many(_store, _triples), do: {:ok, 0}
  def retract(_store, _triple), do: {:ok, 0}
  def query(_store, _pattern), do: {:ok, []}
  def count(_store, _pattern \\ nil), do: {:ok, 0}
  def sparql(_store, _query), do: {:ok, %{results: []}}
end

# ---------------------------------------------------------------------------
# MiosaSignal (top-level) — Signal Theory struct + functions
# ---------------------------------------------------------------------------

defmodule MiosaSignal do
  @moduledoc "Top-level Signal Theory module — wraps the 5-tuple signal struct."

  @type signal_mode :: :execute | :build | :analyze | :maintain | :assist
  @type signal_genre :: :direct | :inform | :commit | :decide | :express
  @type signal_type :: :question | :request | :issue | :scheduling | :summary | :report | :general
  @type signal_format :: :text | :code | :json | :markdown | :binary
  @type signal_structure :: :simple | :compound | :complex

  @type t :: %__MODULE__{
    mode: signal_mode(),
    genre: signal_genre(),
    type: signal_type(),
    format: signal_format(),
    weight: float(),
    content: String.t(),
    metadata: map()
  }

  defstruct mode: :assist, genre: :direct, type: :general,
            format: :text, weight: 0.5, content: "", metadata: %{}

  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  def valid?(%__MODULE__{mode: m, genre: g, type: t, format: f})
      when m in [:execute, :build, :analyze, :maintain, :assist] and
           g in [:direct, :inform, :commit, :decide, :express] and
           t in [:question, :request, :issue, :scheduling, :summary, :report, :general] and
           f in [:text, :code, :json, :markdown, :binary], do: true
  def valid?(_), do: false

  def to_cloud_event(%__MODULE__{} = signal) do
    %{
      specversion: "1.0",
      type: "com.miosa.signal.#{signal.mode}",
      source: "osa-agent",
      id: :erlang.unique_integer([:positive]) |> to_string(),
      data: Map.from_struct(signal)
    }
  end

  def from_cloud_event(%{"data" => data}) when is_map(data) do
    new(for {k, v} <- data, into: %{}, do: {String.to_existing_atom(k), v})
  rescue
    _ -> new(%{})
  end
  def from_cloud_event(_), do: new(%{})

  def measure_sn_ratio(%__MODULE__{weight: w}), do: w
  def measure_sn_ratio(_), do: 0.5
end
