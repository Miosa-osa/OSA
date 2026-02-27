defmodule OptimalSystemAgent.Swarm.Intelligence do
  @moduledoc """
  Swarm Intelligence — Decentralized multi-agent coordination with emergent intelligence.

  Implements a swarm coordination model where agents collaborate through
  shared memory rather than a central controller. Agents have roles:

  - `:explorer`    — Searches the solution space, discovers findings
  - `:specialist`  — Deep domain expertise, detailed analysis
  - `:critic`      — Validates and critiques hypotheses
  - `:synthesizer` — Combines results into cohesive output
  - `:coordinator` — Manages handoffs between agents

  ## Shared Memory

  A `SharedMemory` Agent process stores findings, hypotheses, and consensus
  state. All swarm agents read from and write to this shared state.

  ## Voting & Convergence

  Agents vote on hypotheses (-1.0 to 1.0). When the average weighted vote
  on a hypothesis exceeds the convergence threshold (default 0.8), the
  swarm has reached consensus.

  ## Usage

      # Exploration swarm
      {:ok, result} = Intelligence.explore("Debug the auth timeout issue", num_explorers: 3)

      # Specialist swarm
      {:ok, result} = Intelligence.specialize("Optimize database queries", domains: ["sql", "indexing", "caching"])

  ## Events

  Emits on `Events.Bus`:
    - `%{event: :swarm_intelligence_started, ...}`
    - `%{event: :swarm_intelligence_round, ...}`
    - `%{event: :swarm_intelligence_converged, ...}`
    - `%{event: :swarm_intelligence_completed, ...}`
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  # ── Types ──────────────────────────────────────────────────────────

  @type role :: :explorer | :specialist | :critic | :synthesizer | :coordinator

  @type finding :: %{
          agent_id: String.t(),
          content: term(),
          timestamp: DateTime.t(),
          votes: integer()
        }

  @type hypothesis :: %{
          agent_id: String.t(),
          hypothesis: String.t(),
          confidence: float(),
          votes: [%{agent_id: String.t(), vote: float()}],
          timestamp: DateTime.t()
        }

  @type swarm_state :: %{
          findings: [finding()],
          hypotheses: [hypothesis()],
          consensus: map(),
          messages: [map()]
        }

  # ── Default Config ─────────────────────────────────────────────────

  @default_max_rounds 10
  @default_convergence_threshold 0.8

  # ── SharedMemory (Agent process) ───────────────────────────────────

  defmodule SharedMemory do
    @moduledoc """
    Agent-backed shared memory for swarm intelligence coordination.

    Stores findings, hypotheses, votes, and messages that all swarm
    agents can read and write to. Uses an Elixir Agent process for
    thread-safe concurrent access.
    """

    @doc "Start a new shared memory process."
    @spec start_link(keyword()) :: Agent.on_start()
    def start_link(opts \\ []) do
      name = Keyword.get(opts, :name)

      init_state = %{
        findings: [],
        hypotheses: [],
        consensus: %{},
        messages: []
      }

      if name do
        Agent.start_link(fn -> init_state end, name: name)
      else
        Agent.start_link(fn -> init_state end)
      end
    end

    @doc "Stop the shared memory process."
    @spec stop(pid() | atom()) :: :ok
    def stop(memory) do
      Agent.stop(memory)
    end

    @doc "Add a finding from an agent."
    @spec add_finding(pid() | atom(), String.t(), term()) :: :ok
    def add_finding(memory, agent_id, content) do
      Agent.update(memory, fn state ->
        finding = %{
          agent_id: agent_id,
          content: content,
          timestamp: DateTime.utc_now(),
          votes: 0
        }

        %{state | findings: state.findings ++ [finding]}
      end)
    end

    @doc "Add a hypothesis for other agents to evaluate."
    @spec add_hypothesis(pid() | atom(), String.t(), String.t(), float()) :: :ok
    def add_hypothesis(memory, agent_id, hypothesis, confidence) do
      Agent.update(memory, fn state ->
        h = %{
          agent_id: agent_id,
          hypothesis: hypothesis,
          confidence: min(max(confidence, 0.0), 1.0),
          votes: [],
          timestamp: DateTime.utc_now()
        }

        %{state | hypotheses: state.hypotheses ++ [h]}
      end)
    end

    @doc """
    Vote on a hypothesis by index. Vote must be between -1.0 and 1.0.

    Positive votes indicate agreement, negative indicate disagreement.
    """
    @spec vote_hypothesis(pid() | atom(), String.t(), non_neg_integer(), float()) ::
            :ok | {:error, :out_of_range}
    def vote_hypothesis(memory, agent_id, hypothesis_idx, vote)
        when is_float(vote) and vote >= -1.0 and vote <= 1.0 do
      Agent.update(memory, fn state ->
        case Enum.at(state.hypotheses, hypothesis_idx) do
          nil ->
            state

          _h ->
            hypotheses =
              List.update_at(state.hypotheses, hypothesis_idx, fn h ->
                %{h | votes: h.votes ++ [%{agent_id: agent_id, vote: vote}]}
              end)

            %{state | hypotheses: hypotheses}
        end
      end)
    end

    def vote_hypothesis(_memory, _agent_id, _idx, _vote), do: {:error, :out_of_range}

    @doc """
    Get the hypothesis with highest consensus score.

    Score = average_vote * confidence. Hypotheses without votes get
    a reduced score (confidence * 0.5).
    """
    @spec get_consensus_hypothesis(pid() | atom()) :: map() | nil
    def get_consensus_hypothesis(memory) do
      Agent.get(memory, fn state ->
        if state.hypotheses == [] do
          nil
        else
          state.hypotheses
          |> Enum.map(fn h ->
            score =
              if h.votes != [] do
                avg_vote = Enum.sum(Enum.map(h.votes, & &1.vote)) / length(h.votes)
                avg_vote * h.confidence
              else
                h.confidence * 0.5
              end

            {score, h}
          end)
          |> Enum.sort_by(&elem(&1, 0), :desc)
          |> List.first()
          |> case do
            {_score, h} -> h
            nil -> nil
          end
        end
      end)
    end

    @doc "Broadcast a message to all agents."
    @spec broadcast(pid() | atom(), String.t(), String.t(), term()) :: :ok
    def broadcast(memory, from_agent, message_type, content) do
      Agent.update(memory, fn state ->
        msg = %{
          from: from_agent,
          to: nil,
          type: message_type,
          content: content,
          timestamp: DateTime.utc_now()
        }

        %{state | messages: state.messages ++ [msg]}
      end)
    end

    @doc "Send a directed message to a specific agent."
    @spec send_message(pid() | atom(), String.t(), String.t(), String.t(), term()) :: :ok
    def send_message(memory, from_agent, to_agent, message_type, content) do
      Agent.update(memory, fn state ->
        msg = %{
          from: from_agent,
          to: to_agent,
          type: message_type,
          content: content,
          timestamp: DateTime.utc_now()
        }

        %{state | messages: state.messages ++ [msg]}
      end)
    end

    @doc "Get messages for a specific agent (broadcasts + directed)."
    @spec get_messages_for(pid() | atom(), String.t()) :: [map()]
    def get_messages_for(memory, agent_id) do
      Agent.get(memory, fn state ->
        Enum.filter(state.messages, fn msg ->
          msg.to == nil or msg.to == agent_id
        end)
      end)
    end

    @doc "Get all findings."
    @spec get_findings(pid() | atom()) :: [map()]
    def get_findings(memory) do
      Agent.get(memory, & &1.findings)
    end

    @doc "Get all hypotheses."
    @spec get_hypotheses(pid() | atom()) :: [map()]
    def get_hypotheses(memory) do
      Agent.get(memory, & &1.hypotheses)
    end

    @doc "Get the full shared memory state."
    @spec get_state(pid() | atom()) :: map()
    def get_state(memory) do
      Agent.get(memory, & &1)
    end
  end

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Run an exploration swarm on a task.

  Spawns N explorer agents that search different parts of the solution space,
  a synthesizer that combines findings into hypotheses, and a critic that
  validates them. Runs until convergence or max rounds.

  ## Options

    * `:num_explorers` — number of explorer agents (default: 3)
    * `:max_rounds` — maximum exploration rounds (default: 10)
    * `:convergence_threshold` — vote threshold to stop (default: 0.8)

  Returns `{:ok, result_map}` with findings, hypotheses, convergence status.
  """
  @spec explore(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def explore(task, opts \\ []) do
    num_explorers = Keyword.get(opts, :num_explorers, 3)
    max_rounds = Keyword.get(opts, :max_rounds, @default_max_rounds)
    threshold = Keyword.get(opts, :convergence_threshold, @default_convergence_threshold)
    swarm_id = generate_id()

    Logger.info("[Intelligence] Starting exploration swarm: #{String.slice(task, 0, 80)}")

    Bus.emit(:system_event, %{
      event: :swarm_intelligence_started,
      swarm_id: swarm_id,
      type: :exploration,
      task: String.slice(task, 0, 200)
    })

    {:ok, memory} = SharedMemory.start_link()

    # Define agent roster
    agents =
      Enum.map(1..num_explorers, fn i ->
        %{id: "explorer_#{i}", role: :explorer, capabilities: ["search", "discover", "report"]}
      end) ++
        [
          %{
            id: "synthesizer_1",
            role: :synthesizer,
            capabilities: ["merge", "deduplicate", "summarize"]
          },
          %{id: "critic_1", role: :critic, capabilities: ["validate", "critique", "score"]}
        ]

    # Run rounds
    {rounds, converged} = run_rounds(task, agents, memory, max_rounds, threshold, swarm_id)

    # Get final state
    final_state = SharedMemory.get_state(memory)
    consensus = SharedMemory.get_consensus_hypothesis(memory)

    # Synthesize final output
    final_output = synthesize_exploration(task, final_state, consensus)

    SharedMemory.stop(memory)

    result = %{
      task: task,
      swarm_type: :exploration,
      swarm_id: swarm_id,
      agents: Enum.map(agents, & &1.id),
      total_rounds: length(rounds),
      converged: converged,
      findings_count: length(final_state.findings),
      hypotheses_count: length(final_state.hypotheses),
      consensus_hypothesis: consensus,
      final_output: final_output,
      rounds: rounds
    }

    Bus.emit(:system_event, %{
      event: :swarm_intelligence_completed,
      swarm_id: swarm_id,
      converged: converged,
      rounds: length(rounds)
    })

    Logger.info(
      "[Intelligence] Exploration complete: #{length(rounds)} rounds, converged=#{converged}"
    )

    {:ok, result}
  end

  @doc """
  Run a specialist swarm on a task.

  Spawns specialist agents for each domain, plus a coordinator for handoffs.
  Each specialist provides deep analysis from their domain perspective.

  ## Options

    * `:domains` — list of domain strings (default: ["general"])
    * `:max_rounds` — maximum rounds (default: 5)
    * `:convergence_threshold` — vote threshold (default: 0.8)

  Returns `{:ok, result_map}` with specialist outputs and synthesis.
  """
  @spec specialize(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def specialize(task, opts \\ []) do
    domains = Keyword.get(opts, :domains, ["general"])
    max_rounds = Keyword.get(opts, :max_rounds, 5)
    threshold = Keyword.get(opts, :convergence_threshold, @default_convergence_threshold)
    swarm_id = generate_id()

    Logger.info("[Intelligence] Starting specialist swarm: #{String.slice(task, 0, 80)}")

    Bus.emit(:system_event, %{
      event: :swarm_intelligence_started,
      swarm_id: swarm_id,
      type: :specialist,
      task: String.slice(task, 0, 200)
    })

    {:ok, memory} = SharedMemory.start_link()

    # Define agent roster
    agents =
      Enum.map(domains, fn domain ->
        %{
          id: "specialist_#{domain}",
          role: :specialist,
          capabilities: [domain, "deep_analysis", "expert_opinion"]
        }
      end) ++
        [
          %{
            id: "coordinator_1",
            role: :coordinator,
            capabilities: ["delegate", "route", "handoff"]
          },
          %{id: "synthesizer_1", role: :synthesizer, capabilities: ["merge", "summarize"]}
        ]

    # Phase 1: Each specialist analyzes from their domain
    specialist_results =
      agents
      |> Enum.filter(&(&1.role == :specialist))
      |> Enum.map(fn agent ->
        prompt = """
        You are a #{List.first(agent.capabilities)} specialist.

        Analyze the following task from your domain expertise perspective.
        Provide deep, actionable insights specific to #{List.first(agent.capabilities)}.

        ## Task
        #{task}

        Focus on what matters most from your domain. Be specific and technical.
        """

        case call_llm(prompt) do
          {:ok, output} ->
            SharedMemory.add_finding(memory, agent.id, output)

            SharedMemory.add_hypothesis(
              memory,
              agent.id,
              "#{List.first(agent.capabilities)}: #{String.slice(output, 0, 200)}",
              0.7
            )

            %{
              agent_id: agent.id,
              domain: List.first(agent.capabilities),
              output: output,
              status: :ok
            }

          {:error, reason} ->
            %{
              agent_id: agent.id,
              domain: List.first(agent.capabilities),
              output: inspect(reason),
              status: :failed
            }
        end
      end)

    # Phase 2: Cross-pollination rounds (specialists vote on each other's hypotheses)
    {rounds, converged} = run_rounds(task, agents, memory, max_rounds, threshold, swarm_id)

    # Phase 3: Synthesis
    final_state = SharedMemory.get_state(memory)
    consensus = SharedMemory.get_consensus_hypothesis(memory)
    final_output = synthesize_specialist(task, specialist_results, final_state, consensus)

    SharedMemory.stop(memory)

    result = %{
      task: task,
      swarm_type: :specialist,
      swarm_id: swarm_id,
      domains: domains,
      agents: Enum.map(agents, & &1.id),
      specialist_results: specialist_results,
      total_rounds: length(rounds),
      converged: converged,
      findings_count: length(final_state.findings),
      consensus_hypothesis: consensus,
      final_output: final_output
    }

    Bus.emit(:system_event, %{
      event: :swarm_intelligence_completed,
      swarm_id: swarm_id,
      converged: converged,
      type: :specialist
    })

    Logger.info(
      "[Intelligence] Specialist swarm complete: #{length(specialist_results)} specialists, #{length(rounds)} rounds"
    )

    {:ok, result}
  end

  # ── Round Execution ────────────────────────────────────────────────

  defp run_rounds(task, agents, memory, max_rounds, threshold, swarm_id) do
    Enum.reduce_while(1..max_rounds, {[], false}, fn round_num, {rounds_acc, _converged} ->
      Bus.emit(:system_event, %{
        event: :swarm_intelligence_round,
        swarm_id: swarm_id,
        round: round_num
      })

      round_result = execute_round(task, agents, memory, round_num)

      # Check convergence
      consensus = SharedMemory.get_consensus_hypothesis(memory)
      converged = check_convergence(consensus, threshold)

      updated_rounds = rounds_acc ++ [Map.put(round_result, :round, round_num)]

      if converged do
        Bus.emit(:system_event, %{
          event: :swarm_intelligence_converged,
          swarm_id: swarm_id,
          round: round_num
        })

        Logger.info("[Intelligence] Converged at round #{round_num}")
        {:halt, {updated_rounds, true}}
      else
        {:cont, {updated_rounds, false}}
      end
    end)
  end

  defp execute_round(task, agents, memory, round_num) do
    explorers = Enum.filter(agents, &(&1.role == :explorer))
    synthesizers = Enum.filter(agents, &(&1.role == :synthesizer))
    critics = Enum.filter(agents, &(&1.role == :critic))

    # Phase 1: Explorers search
    explorer_findings =
      Enum.map(explorers, fn agent ->
        existing_findings = SharedMemory.get_findings(memory)

        prompt = """
        You are an explorer agent (round #{round_num}).

        Search for insights about this task from a unique angle.
        Avoid repeating what has already been found.

        ## Task
        #{task}

        ## Existing findings (#{length(existing_findings)} total)
        #{summarize_findings(existing_findings)}

        Provide a concise, novel finding.
        """

        case call_llm(prompt) do
          {:ok, output} ->
            SharedMemory.add_finding(memory, agent.id, output)
            %{agent_id: agent.id, finding: output}

          {:error, _} ->
            %{agent_id: agent.id, finding: nil}
        end
      end)

    # Phase 2: Synthesizers generate hypotheses
    Enum.each(synthesizers, fn agent ->
      findings = SharedMemory.get_findings(memory)

      prompt = """
      You are a synthesizer agent (round #{round_num}).

      Combine the #{length(findings)} findings into a cohesive hypothesis.
      State your hypothesis clearly and rate your confidence (0.0 to 1.0).

      Begin with: HYPOTHESIS: [your hypothesis]
      Then: CONFIDENCE: [0.0-1.0]

      ## Findings
      #{summarize_findings(findings)}
      """

      case call_llm(prompt) do
        {:ok, output} ->
          {hypothesis_text, confidence} = parse_hypothesis(output)
          SharedMemory.add_hypothesis(memory, agent.id, hypothesis_text, confidence)

        {:error, _} ->
          :ok
      end
    end)

    # Phase 3: Critics vote
    hypotheses = SharedMemory.get_hypotheses(memory)

    Enum.each(critics, fn agent ->
      hypotheses
      |> Enum.with_index()
      |> Enum.each(fn {h, idx} ->
        # Only vote on hypotheses this critic hasn't voted on yet
        already_voted = Enum.any?(h.votes, &(&1.agent_id == agent.id))

        unless already_voted do
          prompt = """
          You are a critic agent. Evaluate this hypothesis:

          "#{h.hypothesis}"

          Rate it from -1.0 (completely wrong) to 1.0 (strongly agree).
          Respond with just the number.
          """

          case call_llm(prompt) do
            {:ok, output} ->
              vote = parse_vote(output)
              SharedMemory.vote_hypothesis(memory, agent.id, idx, vote)

            {:error, _} ->
              :ok
          end
        end
      end)
    end)

    %{
      explorer_findings: explorer_findings,
      hypotheses_count: length(SharedMemory.get_hypotheses(memory)),
      findings_count: length(SharedMemory.get_findings(memory))
    }
  end

  # ── Convergence Check ──────────────────────────────────────────────

  defp check_convergence(nil, _threshold), do: false

  defp check_convergence(hypothesis, threshold) do
    case hypothesis.votes do
      [] ->
        false

      votes ->
        avg_vote = Enum.sum(Enum.map(votes, & &1.vote)) / length(votes)
        avg_vote >= threshold
    end
  end

  # ── Synthesis ──────────────────────────────────────────────────────

  defp synthesize_exploration(task, state, consensus) do
    findings_text = summarize_findings(state.findings)

    consensus_text =
      if consensus do
        "Consensus hypothesis: #{consensus.hypothesis} (confidence: #{consensus.confidence})"
      else
        "No consensus reached."
      end

    prompt = """
    Synthesize the results of a multi-agent exploration into a final answer.

    ## Original Task
    #{task}

    ## Findings (#{length(state.findings)})
    #{findings_text}

    ## #{consensus_text}

    Produce a cohesive, actionable response that incorporates the best findings.
    """

    case call_llm(prompt) do
      {:ok, output} ->
        output

      {:error, _} ->
        "Exploration complete with #{length(state.findings)} findings. #{consensus_text}"
    end
  end

  defp synthesize_specialist(task, specialist_results, _state, consensus) do
    specialist_text =
      specialist_results
      |> Enum.filter(&(&1.status == :ok))
      |> Enum.map(fn r -> "### #{r.domain}\n#{r.output}" end)
      |> Enum.join("\n\n---\n\n")

    consensus_text =
      if consensus do
        "Consensus: #{consensus.hypothesis}"
      else
        "No consensus reached."
      end

    prompt = """
    Synthesize specialist analyses into a unified response.

    ## Original Task
    #{task}

    ## Specialist Analyses
    #{specialist_text}

    ## #{consensus_text}

    Merge the specialist perspectives into a comprehensive, cohesive answer.
    """

    case call_llm(prompt) do
      {:ok, output} -> output
      {:error, _} -> "Specialist analysis complete. #{consensus_text}\n\n#{specialist_text}"
    end
  end

  # ── LLM Interface ─────────────────────────────────────────────────

  defp call_llm(prompt) do
    messages = [
      %{
        role: "system",
        content: "You are a focused, concise agent in a multi-agent swarm. Be specific and brief."
      },
      %{role: "user", content: prompt}
    ]

    case Providers.chat(messages, temperature: 0.5) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, _} ->
        {:error, :empty_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Parsing Helpers ────────────────────────────────────────────────

  defp parse_hypothesis(output) do
    hypothesis =
      case Regex.run(~r/HYPOTHESIS:\s*(.+)/i, output) do
        [_, text] -> String.trim(text)
        nil -> String.slice(output, 0, 200)
      end

    confidence =
      case Regex.run(~r/CONFIDENCE:\s*([\d.]+)/i, output) do
        [_, score_str] ->
          case Float.parse(score_str) do
            {val, _} -> min(max(val, 0.0), 1.0)
            :error -> 0.7
          end

        nil ->
          0.7
      end

    {hypothesis, confidence}
  end

  defp parse_vote(output) do
    case Float.parse(String.trim(output)) do
      {vote, _} -> min(max(vote, -1.0), 1.0)
      :error -> 0.0
    end
  end

  defp summarize_findings(findings) do
    findings
    |> Enum.take(20)
    |> Enum.with_index(1)
    |> Enum.map(fn {f, i} ->
      content =
        case f.content do
          text when is_binary(text) -> String.slice(text, 0, 300)
          other -> inspect(other) |> String.slice(0, 300)
        end

      "#{i}. [#{f.agent_id}] #{content}"
    end)
    |> Enum.join("\n")
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp generate_id do
    "si_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
