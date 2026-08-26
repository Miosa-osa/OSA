defmodule OptimalSystemAgent.Agent.Memory.KnowledgeBridge do
  @moduledoc """
  Lightweight bridge that syncs Learning patterns and solutions into the
  knowledge graph as RDF-style triples.

  Runs as a GenServer in the AgentServices supervision tree. Every 60 seconds
  (and once on startup) it reads `Learning.patterns/0` and `Learning.solutions/0`,
  then batch-asserts them into the `osa_default` knowledge store.

  The sync is best-effort: if the knowledge store is not running (e.g. during
  test teardown or before `start_knowledge_store/0` completes) the call is
  silently skipped. All errors are rescued so this process never crashes on a
  knowledge store failure.

  ## Triple vocabulary

  Patterns (frequency counters):

      {"pattern:<key>", "rdf:type",  "osa:LearnedPattern"}
      {"pattern:<key>", "osa:frequency", "<count>"}

  Solutions (error-type → resolution text):

      {"error:<type>", "rdf:type",  "osa:KnownError"}
      {"error:<type>", "osa:solution", "<text>"}
  """

  use GenServer

  require Logger

  alias OptimalSystemAgent.Agent.Learning

  @compile {:no_warn_undefined, OptimalSystemAgent.Agent.Learning}

  @sync_interval_ms 60_000
  @store_name "osa_default"

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an immediate sync outside the periodic schedule (mainly for tests)."
  def sync_now do
    GenServer.call(__MODULE__, :sync_now)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Perform an initial sync after a short delay so the knowledge store has
    # time to fully initialise before the first call.
    Process.send_after(self(), :sync, 5_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    sync_to_knowledge()
    schedule_next_sync()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:sync_now, _from, state) do
    result = sync_to_knowledge()
    {:reply, result, state}
  end

  # ── Internals ───────────────────────────────────────────────────────────────

  defp schedule_next_sync do
    Process.send_after(self(), :sync, @sync_interval_ms)
  end

  defp store_ref do
    {:via, Registry, {MiosaKnowledge.Registry, @store_name}}
  end

  defp sync_to_knowledge do
    case GenServer.whereis(store_ref()) do
      nil ->
        :ok

      _pid ->
        triples = build_pattern_triples() ++ build_solution_triples()

        if triples != [] do
          MiosaKnowledge.assert_many(store_ref(), triples)
        end

        :ok
    end
  rescue
    err ->
      Logger.debug("[KnowledgeBridge] sync skipped: #{Exception.message(err)}")
      :ok
  end

  defp build_pattern_triples do
    Learning.patterns()
    |> Enum.flat_map(fn {key, count} ->
      subject = "pattern:#{key}"

      [
        {subject, "rdf:type", "osa:LearnedPattern"},
        {subject, "osa:frequency", to_string(count)}
      ]
    end)
  rescue
    _ -> []
  end

  defp build_solution_triples do
    Learning.solutions()
    |> Enum.flat_map(fn {error_type, solution} ->
      subject = "error:#{error_type}"

      [
        {subject, "rdf:type", "osa:KnownError"},
        {subject, "osa:solution", solution}
      ]
    end)
  rescue
    _ -> []
  end
end
