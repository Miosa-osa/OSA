defmodule OptimalSystemAgent.Memory.Dream do
  @moduledoc """
  Dream-memory — background consolidation of recent sessions into durable memory.

  Ported in spirit from grok-build's `autoDream`: during idle periods the agent
  performs a "dream" — a reflective pass over recent session transcripts that
  distills them into durable long-term memories (decisions, patterns, lessons,
  preferences, project facts). Each distilled item is written through the
  existing `OptimalSystemAgent.Memory` facade, so the Store's Mem0-style
  ADD/UPDATE/NOOP consolidation transparently handles dedup and merging.

  ## Safety properties

    * **Never blocks the hot path** — the GenServer only schedules; every DB read
      and LLM call runs in a supervised `Task` under `OptimalSystemAgent.TaskSupervisor`.
      The `:check` handler does an in-memory time-gate only.
    * **Idle-gated** — a cycle aborts unless the newest session activity is older
      than `idle_threshold_ms` (the system is quiet).
    * **Rate-limited** — a cycle aborts unless `min_interval_ms` has elapsed since
      the last successful dream (`last_dream_at`, persisted to
      `~/.osa/dream_state.json` so it survives restarts), and only one cycle runs
      at a time (`running?` flag).
    * **Configurable** — see `dream_config/0`. Set `enabled: false` to disable.

  ## Config (`config/*.exs`)

      config :optimal_system_agent, :memory_dream,
        enabled: true,
        check_interval_ms: 30 * 60 * 1000,   # how often to poll the gates
        min_interval_ms: 4 * 60 * 60 * 1000, # min gap between dreams
        idle_threshold_ms: 90_000,           # system must be quiet this long
        min_sessions: 2,                     # need this many new sessions
        max_sessions: 12,                    # consolidate at most this many
        max_input_chars: 24_000,             # total transcript budget
        max_session_chars: 6_000,            # per-session transcript cap
        min_session_chars: 200               # skip trivially short sessions

  The consolidation core (`consolidate/2`, `parse_response/1`, `build_prompt/1`,
  gating predicates) is pure and dependency-injected for tests — the LLM and the
  Store are passed as `:chat_fun` / `:save_fun`.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Store.SessionTranscript
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @valid_categories ~w(decision pattern lesson preference project context)

  @default_config [
    enabled: true,
    check_interval_ms: 30 * 60 * 1000,
    min_interval_ms: 4 * 60 * 60 * 1000,
    idle_threshold_ms: 90_000,
    min_sessions: 2,
    max_sessions: 12,
    max_input_chars: 24_000,
    max_session_chars: 6_000,
    min_session_chars: 200
  ]

  @system_prompt """
  You are performing a "dream" — a reflective consolidation pass over an agent's
  recent work sessions. Your job is to distill the transcripts into a small set
  of DURABLE, self-contained memories that will help future sessions orient
  quickly, long after the current conversations are forgotten.

  Guidelines:
  1. MERGE related facts across sessions into single coherent statements.
  2. RESOLVE contradictions — if a later session disproves an earlier fact, keep
     only the current truth.
  3. PRESERVE decisions, rationale, architecture, user preferences, and
     problem/solution pairs.
  4. DISCARD ephemera — greetings, tool-output noise, message counts, transient
     "current state" or "next steps", and anything already obvious.
  5. Convert relative dates ("yesterday", "last week") to absolute where known.
  6. Each memory must be a single, self-contained sentence understandable with no
     other context.

  Output format — one memory per line, each prefixed with its category in
  brackets, where category is one of: decision, pattern, lesson, preference,
  project, context. Example:

  [decision] The team standardized on Ecto over raw SQL for all DB access.
  [lesson] Passing workers above 16 to the test runner causes flaky failures.

  Output ONLY the bracketed lines, nothing else. If nothing in the transcripts is
  worth persisting, respond with exactly: NO_REPLY
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force a dream cycle now, bypassing the time gate (idle/session gates still apply unless forced)."
  @spec dream_now(keyword()) :: :ok
  def dream_now(opts \\ []) do
    GenServer.cast(__MODULE__, {:dream_now, opts})
  end

  @doc "Return runtime stats for the dream process."
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "The effective, merged dream config (defaults <- application env)."
  @spec dream_config() :: keyword()
  def dream_config do
    env = Application.get_env(:optimal_system_agent, :memory_dream, [])
    Keyword.merge(@default_config, env)
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    cfg = dream_config()

    state = %{
      running?: false,
      last_dream_at: load_last_dream_at(),
      stats: %{cycles: 0, dreams: 0, neutral: 0, errors: 0, saved: 0}
    }

    if cfg[:enabled] do
      schedule_check(cfg[:check_interval_ms])
      Logger.info("[Dream] enabled — check every #{cfg[:check_interval_ms]}ms")
    else
      Logger.info("[Dream] disabled via config")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    cfg = dream_config()
    if cfg[:enabled], do: schedule_check(cfg[:check_interval_ms])

    # In-memory time-gate only — no DB / LLM work on the GenServer.
    state =
      case gate_time(state.last_dream_at, now(), cfg[:min_interval_ms], _force = false) do
        :ok -> maybe_spawn(state, cfg, force: false)
        {:skip, _reason} -> state
      end

    {:noreply, state}
  end

  # Task completion arrives here.
  @impl true
  def handle_info({ref, _}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    if reason != :normal do
      Logger.warning("[Dream] cycle task crashed: #{inspect(reason)}")
    end

    {:noreply, %{state | running?: false}}
  end

  @impl true
  def handle_cast({:dream_now, _opts}, state) do
    cfg = dream_config()
    {:noreply, maybe_spawn(state, cfg, force: true)}
  end

  @impl true
  def handle_cast({:dream_result, result}, state) do
    {:noreply, apply_result(state, result)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.put(state.stats, :last_dream_at, state.last_dream_at), state}
  end

  # ---------------------------------------------------------------------------
  # Cycle orchestration (impure — runs inside a supervised Task)
  # ---------------------------------------------------------------------------

  defp maybe_spawn(%{running?: true} = state, _cfg, _), do: state

  defp maybe_spawn(state, cfg, opts) do
    force = Keyword.get(opts, :force, false)
    server = self()
    last = state.last_dream_at

    Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
      result = run_cycle(cfg, last, force)
      GenServer.cast(server, {:dream_result, result})
    end)

    %{state | running?: true}
  end

  @doc false
  # Full cycle: gate on idle + session count, gather transcripts, consolidate.
  def run_cycle(cfg, last_dream_at, force) do
    sessions = safe_list_sessions(cfg[:max_sessions] * 3)

    with :ok <- gate_time(last_dream_at, now(), cfg[:min_interval_ms], force),
         :ok <- gate_idle(sessions, now(), cfg[:idle_threshold_ms], force),
         eligible = eligible_sessions(sessions, last_dream_at, cfg[:max_sessions]),
         :ok <- gate_sessions(eligible, cfg[:min_sessions], force) do
      texts = gather_texts(eligible, cfg)

      if texts == [] do
        %{status: :neutral, reason: :no_content, saved: 0, sessions: 0}
      else
        consolidate(texts, cfg)
      end
    else
      {:skip, reason} -> %{status: :skipped, reason: reason, saved: 0, sessions: 0}
    end
  rescue
    e ->
      Logger.warning("[Dream] cycle error: #{Exception.message(e)}")
      %{status: :error, reason: Exception.message(e), saved: 0, sessions: 0}
  end

  @doc """
  Consolidate prepared session texts into durable memories.

  `texts` is a list of `%{id: session_id, text: transcript}`. `opts` (or config
  keyword list) may provide:

    * `:chat_fun` — `fn system, user -> {:ok, String.t()} | {:error, term()}` end
      (default: real LLM call via the provider registry)
    * `:save_fun` — `fn content, keyword -> {:ok, map} | {:error, term()}` end
      (default: `OptimalSystemAgent.Memory.save/2`)
    * `:max_input_chars` — total prompt budget

  Returns a report map with `:status`, `:saved`, `:skipped`, `:sessions`.
  """
  @spec consolidate([map()], keyword()) :: map()
  def consolidate(texts, opts) do
    chat_fun = Keyword.get(opts, :chat_fun, &default_chat/2)
    save_fun = Keyword.get(opts, :save_fun, &default_save/2)
    {system, user} = build_prompt(texts, opts)

    case chat_fun.(system, user) do
      {:ok, response} ->
        case parse_response(response) do
          :no_reply ->
            %{status: :neutral, reason: :no_reply, saved: 0, sessions: length(texts)}

          {:ok, items} ->
            {saved, skipped} = persist_items(items, save_fun)

            %{
              status: :completed,
              saved: saved,
              skipped: skipped,
              items: length(items),
              sessions: length(texts)
            }
        end

      {:error, reason} ->
        %{status: :error, reason: reason, saved: 0, sessions: length(texts)}
    end
  end

  defp persist_items(items, save_fun) do
    Enum.reduce(items, {0, 0}, fn %{category: cat, content: content}, {ok, skip} ->
      opts = [
        category: cat,
        source: :sica,
        scope: :global,
        signal_weight: 0.6,
        tags: ["dream", "consolidated"],
        description: "dream-consolidated memory"
      ]

      case safe_save(save_fun, content, opts) do
        {:ok, _} -> {ok + 1, skip}
        _ -> {ok, skip + 1}
      end
    end)
  end

  defp safe_save(save_fun, content, opts) do
    save_fun.(content, opts)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Pure gating predicates (testable)
  # ---------------------------------------------------------------------------

  @doc "Time gate: has `min_interval_ms` elapsed since the last dream? `force` bypasses."
  @spec gate_time(NaiveDateTime.t() | nil, NaiveDateTime.t(), non_neg_integer(), boolean()) ::
          :ok | {:skip, {:too_soon, non_neg_integer()}}
  def gate_time(_last, _now, _min, true), do: :ok
  def gate_time(nil, _now, _min, _force), do: :ok

  def gate_time(last, now, min_interval_ms, _force) do
    elapsed = NaiveDateTime.diff(now, last, :millisecond)
    if elapsed >= min_interval_ms, do: :ok, else: {:skip, {:too_soon, elapsed}}
  end

  @doc "Idle gate: is the newest session activity older than `idle_threshold_ms`? `force` bypasses."
  @spec gate_idle([map()], NaiveDateTime.t(), non_neg_integer(), boolean()) ::
          :ok | {:skip, {:busy, non_neg_integer()}}
  def gate_idle(_sessions, _now, _threshold, true), do: :ok
  def gate_idle([], _now, _threshold, _force), do: :ok

  def gate_idle(sessions, now, idle_threshold_ms, _force) do
    latest =
      sessions
      |> Enum.map(&parse_ts(&1[:last_active] || &1["last_active"]))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        list -> Enum.max_by(list, &NaiveDateTime.to_gregorian_seconds/1)
      end

    cond do
      is_nil(latest) -> :ok
      NaiveDateTime.diff(now, latest, :millisecond) >= idle_threshold_ms -> :ok
      true -> {:skip, {:busy, NaiveDateTime.diff(now, latest, :millisecond)}}
    end
  end

  @doc "Session gate: are there at least `min_sessions` eligible sessions? `force` bypasses (>=1)."
  @spec gate_sessions([map()], non_neg_integer(), boolean()) ::
          :ok | {:skip, {:too_few_sessions, non_neg_integer()}}
  def gate_sessions(eligible, _min, true) do
    if eligible == [], do: {:skip, {:too_few_sessions, 0}}, else: :ok
  end

  def gate_sessions(eligible, min_sessions, _force) do
    n = length(eligible)
    if n >= min_sessions, do: :ok, else: {:skip, {:too_few_sessions, n}}
  end

  @doc """
  Select sessions eligible for consolidation: those active since `last_dream_at`
  (all, if nil), newest first, capped to `max_sessions`.
  """
  @spec eligible_sessions([map()], NaiveDateTime.t() | nil, pos_integer()) :: [map()]
  def eligible_sessions(sessions, last_dream_at, max_sessions) do
    sessions
    |> Enum.filter(fn s ->
      ts = parse_ts(s[:last_active] || s["last_active"])

      cond do
        is_nil(ts) -> false
        is_nil(last_dream_at) -> true
        true -> NaiveDateTime.compare(ts, last_dream_at) == :gt
      end
    end)
    |> Enum.sort_by(
      fn s -> parse_ts(s[:last_active] || s["last_active"]) |> NaiveDateTime.to_gregorian_seconds() end,
      :desc
    )
    |> Enum.take(max_sessions)
  end

  # ---------------------------------------------------------------------------
  # Pure prompt building + response parsing (testable)
  # ---------------------------------------------------------------------------

  @doc "Build the `{system, user}` prompt pair from prepared session texts (budget-capped)."
  @spec build_prompt([map()], keyword()) :: {String.t(), String.t()}
  def build_prompt(texts, opts \\ []) do
    budget = Keyword.get(opts, :max_input_chars, @default_config[:max_input_chars])

    {user, _} =
      Enum.reduce_while(texts, {"", 0}, fn %{id: id, text: text}, {acc, used} ->
        block = "--- Session #{id} ---\n#{text}\n\n"

        if used + byte_size(block) > budget and acc != "" do
          {:halt, {acc, used}}
        else
          {:cont, {acc <> block, used + byte_size(block)}}
        end
      end)

    {@system_prompt, String.trim_trailing(user)}
  end

  @doc """
  Parse the dream model response into `{:ok, [%{category, content}]}` or `:no_reply`.

  Accepts `[category] content` lines (unknown categories coerced to `context`).
  If no bracketed lines are found, non-empty non-header lines are kept as
  `context` so a model that ignores the format still yields memories.
  """
  @spec parse_response(String.t()) :: {:ok, [map()]} | :no_reply
  def parse_response(response) when is_binary(response) do
    trimmed = String.trim(response)

    if no_reply?(trimmed) do
      :no_reply
    else
      lines = trimmed |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      bracketed = Enum.flat_map(lines, &parse_bracket_line/1)

      items =
        if bracketed == [] do
          lines
          |> Enum.reject(&fallback_noise?/1)
          |> Enum.map(fn line -> %{category: :context, content: strip_bullet(line)} end)
        else
          bracketed
        end

      items = dedup_items(items)
      if items == [], do: :no_reply, else: {:ok, items}
    end
  end

  defp parse_bracket_line(line) do
    case Regex.run(~r/^\[(\w+)\]\s*(.+)$/, line) do
      [_, cat, content] ->
        content = String.trim(content)
        if String.length(content) >= 3, do: [%{category: coerce_category(cat), content: content}], else: []

      _ ->
        []
    end
  end

  defp coerce_category(cat) do
    c = String.downcase(cat)
    if c in @valid_categories, do: String.to_atom(c), else: :context
  end

  defp no_reply?(text) do
    normalized = text |> String.upcase() |> String.replace(~r/[^A-Z_]/, "")
    text == "" or normalized == "NOREPLY" or String.starts_with?(text, "NO_REPLY")
  end

  defp fallback_noise?(line) do
    line == "" or String.starts_with?(line, "#") or String.length(strip_bullet(line)) < 8
  end

  defp strip_bullet(line), do: String.replace(line, ~r/^[-*]\s+/, "")

  defp dedup_items(items) do
    items
    |> Enum.uniq_by(fn %{content: c} -> c |> String.downcase() |> String.trim() end)
  end

  # ---------------------------------------------------------------------------
  # Impure helpers
  # ---------------------------------------------------------------------------

  defp gather_texts(eligible, cfg) do
    max_session = cfg[:max_session_chars]
    min_session = cfg[:min_session_chars]

    eligible
    |> Enum.map(fn s ->
      id = s[:session_id] || s["session_id"]
      %{id: id, text: format_transcript(id, max_session)}
    end)
    |> Enum.reject(fn %{text: t} -> byte_size(t) < min_session end)
  end

  defp format_transcript(session_id, max_chars) do
    session_id
    |> SessionTranscript.get_transcript()
    |> Enum.map(fn r ->
      role = r.role || "?"
      content = r.content || ""
      "#{role}: #{content}"
    end)
    |> Enum.join("\n")
    |> truncate(max_chars)
  rescue
    _ -> ""
  end

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: binary_part(s, 0, max)

  defp safe_list_sessions(limit) do
    SessionTranscript.list_sessions(limit: limit)
  rescue
    _ -> []
  end

  defp default_chat(system, user) do
    messages = [
      %{role: "system", content: system},
      %{role: "user", content: user}
    ]

    case Providers.chat(messages, temperature: 0.2, max_tokens: 1024) do
      {:ok, %{content: content}} when is_binary(content) and content != "" -> {:ok, content}
      {:ok, other} -> {:error, {:empty_response, other}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp default_save(content, opts), do: Memory.save(content, opts)

  # ---------------------------------------------------------------------------
  # State + persistence
  # ---------------------------------------------------------------------------

  defp apply_result(state, result) do
    stats = state.stats
    s = %{stats | cycles: stats.cycles + 1}

    {state, s} =
      case result.status do
        :completed ->
          saved = Map.get(result, :saved, 0)
          now = now()
          persist_last_dream_at(now)
          {%{state | last_dream_at: now}, %{s | dreams: s.dreams + 1, saved: s.saved + saved}}

        :neutral ->
          # A quiet dream still counts as "done" for rate-limiting purposes.
          now = now()
          persist_last_dream_at(now)
          {%{state | last_dream_at: now}, %{s | neutral: s.neutral + 1}}

        :skipped ->
          {state, s}

        :error ->
          {state, %{s | errors: s.errors + 1}}
      end

    Logger.info("[Dream] cycle #{result.status} — #{inspect(Map.delete(result, :status))}")
    %{state | running?: false, stats: s}
  end

  defp schedule_check(interval_ms), do: Process.send_after(self(), :check, interval_ms)

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp state_file do
    dir = Application.get_env(:optimal_system_agent, :config_dir, Path.expand("~/.osa"))
    Path.join(dir, "dream_state.json")
  end

  defp load_last_dream_at do
    with {:ok, body} <- File.read(state_file()),
         {:ok, %{"last_dream_at" => ts}} when is_binary(ts) <- Jason.decode(body),
         {:ok, dt} <- NaiveDateTime.from_iso8601(ts) do
      dt
    else
      _ -> nil
    end
  end

  defp persist_last_dream_at(dt) do
    file = state_file()
    File.mkdir_p(Path.dirname(file))
    File.write(file, Jason.encode!(%{last_dream_at: NaiveDateTime.to_iso8601(dt)}))
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Timestamp parsing (shared)
  # ---------------------------------------------------------------------------

  @doc false
  def parse_ts(nil), do: nil
  def parse_ts(%NaiveDateTime{} = t), do: t

  def parse_ts(s) when is_binary(s) do
    normalized = String.replace(s, " ", "T", global: false)

    case NaiveDateTime.from_iso8601(normalized) do
      {:ok, t} -> t
      _ -> nil
    end
  end

  def parse_ts(_), do: nil
end
