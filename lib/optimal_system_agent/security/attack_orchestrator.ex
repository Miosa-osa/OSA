defmodule OptimalSystemAgent.Security.AttackOrchestrator do
  @moduledoc """
  Autonomous attack orchestration — coordinates recon → enumeration → exploitation → post-exploitation.

  Takes findings from the intelligence layer and chains them into coordinated
  attack sequences without agent intervention. Uses ShadowGraph for path selection,
  AttackTree for class prioritization, and ClassQueue to track exploit candidates.

  ## Lifecycle

      # Start an orchestration session
      {:ok, pid} = AttackOrchestrator.start_link(session_id: "eng-001")

      # Feed in findings (recon results, vulnerabilities, anomalies)
      :ok = AttackOrchestrator.feed(pid, %{category: :finding, target: "10.0.0.5", ...})

      # Run the orchestration loop
      {:results, state} = AttackOrchestrator.run(pid)

  """

  use GenServer

  alias OptimalSystemAgent.Security.{
    ShadowGraph,
    AttackTree,
    ClassQueue,
    AnomalyQueue,
    ThreatIntel,
    WeaponCatalog,
    ExploitGenerator,
    LiveExploitRunner,
    AttackChainReasoner,
    AttackPrioritizer
  }

  @typedoc "Orchestration phase states"
  @type phase() :: :recon | :enumeration | :exploitation | :post_exploitation | :complete

  @typedoc "Orchestration state"
  @type state() :: %{
          session_id: String.t(),
          phase: phase(),
          findings: [map()],
          weapons: [map()],
          attack_sequence: [{atom(), map()}],
          completed: [String.t()],
          failed: [String.t()],
          next_target: String.t() | nil,
          confidence_threshold: float()
        }

  @default_confidence 0.7

  # ── GenServer API ───────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    session_id = Keyword.get(opts, :session_id, "eng-#{:erlang.phash2(self(), 1000)}")
    GenServer.start_link(__MODULE__, opts, name: String.to_atom("osa_attack_ora_#{session_id}"))
  end

  @spec init(keyword()) :: {:ok, state()} | {:error, String.t()}
  def init(opts) do
    session_id = Keyword.get(opts, :session_id, "eng-#{:erlang.phash2(self(), 1000)}")
    confidence_threshold = Keyword.get(opts, :confidence_threshold, @default_confidence)

    state = %{
      session_id: session_id,
      phase: :recon,
      findings: [],
      weapons: [],
      attack_sequence: [],
      completed: [],
      failed: [],
      next_target: nil,
      confidence_threshold: confidence_threshold
    }

    ensure_registry()
    :ets.insert(:osa_attack_ora, {session_id, self()})

    {:ok, state}
  end

  @doc "Feed a finding into the orchestrator for processing."
  @spec feed(pid() | atom(), map()) :: :ok | {:error, String.t()}
  def feed(pid_or_atom, finding) when is_pid(pid_or_atom) or is_atom(pid_or_atom) do
    GenServer.cast(pid_or_atom, {:feed, finding})
  end

  @doc "Feed a finding from the calling process."
  @spec feed(map()) :: :ok | {:error, String.t()}
  def feed(finding) when is_map(finding) do
    # Find the orchestrator GenServer by session_id pattern matching
    case find_by_session(session_id_of_finding(finding)) do
      pid when is_pid(pid) -> feed(pid, finding)
      :not_found -> {:error, "no running orchestrator for this session"}
    end
  end

  @doc "Run the full orchestration loop until complete or blocked."
  @spec run(pid() | atom()) :: {:results, state()} | {:blocked, String.t()}
  def run(pid_or_atom) when is_pid(pid_or_atom) or is_atom(pid_or_atom) do
    GenServer.call(pid_or_atom, :run)
  end

  # ── Cast handlers ───────────────────────────────────────────────────────

  @spec handle_cast({atom(), any()}, state()) :: {:noreply, state()} | {:stop, atom(), state()}
  def handle_cast({:feed, finding}, state) do
    new_findings = [finding | state.findings]
    weaponized = WeaponCatalog.classify(finding, state.weapons)

    {:noreply, %{state | findings: new_findings, weapons: weaponized}}
  end

  def handle_cast(:advance_phase, state) do
    next_phase =
      case state.phase do
        :recon -> :enumeration
        :enumeration -> :exploitation
        :exploitation -> :post_exploitation
        :post_exploitation -> :complete
        :complete -> :complete
      end

    {:noreply, %{state | phase: next_phase}}
  end

  # ── Call handlers ───────────────────────────────────────────────────────

  @spec handle_call(atom(), any(), state()) :: {:reply, any(), state()}
  def handle_call(:run, _from, state) do
    result = execute_sequence(state)
    {:reply, result, state}
  end

  # ── Internal logic ──────────────────────────────────────────────────────

  @doc """
  Execute the full attack sequence.

  Traverses ShadowGraph for paths, feeds ClassQueue with prioritized candidates,
  runs exploits via LiveExploitRunner, and collects results into completed/failed.
  """
  @spec execute_sequence(state()) :: {:results, state()} | {:blocked, String.t()}
  def execute_sequence(%{phase: :complete} = state) do
    completed_count = length(state.completed)
    failed_count = length(state.failed)

    if completed_count > 0 or failed_count > 0 do
      {:results, state}
    else
      {:blocked, "no findings to process"}
    end
  end

  def execute_sequence(state) do
    # Step 1: Use ShadowGraph to find attack paths from current recon data
    graph_paths = ShadowGraph.attack_paths(state.session_id) || []

    # Step 2: Feed AttackTree with prioritized classes (basics first)
    class_priorities = AttackTree.next_classes(state.session_id, max: length(graph_paths))

    # Step 3: Classify all findings as weapons
    weaponized = WeaponCatalog.classify_batch(state.findings)

    # Step 4: Prioritize targets by exploitability × impact
    prioritized = AttackPrioritizer.rank(weaponized)

    # Step 5: Feed into ClassQueue in priority order
    Enum.each(prioritized, fn weapon ->
      entry = %{
        class: weapon.class,
        target: weapon.target,
        confidence: weapon.score,
        evidence: weapon.evidence
      }

      ClassQueue.enqueue(state.session_id, entry)
    end)

    # Step 6: Deploy exploits via LiveExploitRunner
    results =
      Enum.map(prioritized, fn weapon ->
        case LiveExploitRunner.deploy(weapon) do
          {:ok, result}
          when is_map(result) and is_map_key(result, :confirmed) and
                 :erlang.map_get(:confirmed, result) == true ->
            %{state.completed | end: [weapon.target]}
            {:depleted, result}

          {:ok, result} ->
            # Not confirmed yet — feed into AnomalyQueue for follow-one-hop
            AnomalyQueue.record(state.session_id, %{
              target: weapon.target,
              class: weapon.class,
              anomaly_type: :unconfirmed_exploit,
              evidence: result
            })

            {:potential, result}

          :error ->
            {:failed, weapon.target}
        end
      end)

    # Step 7: Check for post-exploitation opportunities via ChainReasoner
    chains = AttackChainReasoner.find_chains(state.session_id)

    new_weapons =
      chains
      |> Enum.flat_map(& &1.hops)
      |> Enum.map(fn hop ->
        %{
          id: "chain-#{:erlang.phash2(hop, 1000)}",
          domain: hop.vulnerability_class || :rce,
          target: hop.target,
          score: hop_score_to_weapon_score(hop),
          maturity: :poc,
          is_kev: hop.has_kev,
          code_reachable: true,
          evidence_count: 1
        }
      end)

    final_state = %{state | weapons: state.weapons ++ new_weapons}

    {:results, final_state}
  end

  @doc """
  Get the next target to attack based on prioritization.
  Considers confidence threshold and evidence quality.
  """
  @spec next_target(state()) :: map() | nil
  def next_target(%{weapons: weapons, confidence_threshold: threshold})
      when is_list(weapons) do
    weapons
    |> AttackPrioritizer.rank()
    |> Enum.find(&(&1.confidence >= threshold))
  end

  def next_target(_state), do: nil

  # ── Helpers ─────────────────────────────────────────────────────────────

  @spec find_by_session(String.t()) :: pid() | :not_found
  defp find_by_session(session_id) when is_binary(session_id) do
    :ets.foldl(
      fn {sid, pid}, acc ->
        if sid == session_id, do: pid, else: acc
      end,
      :not_found,
      :osa_attack_ora
    )
  end

  @spec session_id_of_finding(map()) :: String.t() | nil
  defp session_id_of_finding(finding) when is_map(finding) do
    Map.get(finding, :session_id) || Map.get(finding, "session_id")
  end

  @spec ensure_registry() :: :ok
  defp ensure_registry do
    case :ets.whereis(:osa_attack_ora) do
      :undefined -> :ets.new(:osa_attack_ora, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  @spec hop_score_to_weapon_score(map()) :: float()
  defp hop_score_to_weapon_score(hop) do
    (Map.get(hop, :edge_weight, 0.5) * 0.6 + Map.get(hop, :evidence_quality, 0.5) * 0.4)
    |> min(1.0)
  end
end
