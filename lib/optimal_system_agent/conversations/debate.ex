defmodule OptimalSystemAgent.Conversations.Debate do
  @moduledoc """
  Structured debate protocol.

  Formal debate cycle: **propose → critique → revise → vote**

  Each round the proposer presents or refines the proposition, critics respond
  in turn, and voters assign a score (0–10). If vote scores improve by less than
  5% between rounds, the debate ends early (convergence). The debate also ends
  early once the configured consensus policy is met.

  ## Usage

      {:ok, result} = Debate.start_debate(
        proposition: "We should migrate to event sourcing",
        proposer: %Persona{name: "alice", role: "Architect", ...},
        critics: [%Persona{name: "bob", ...}, :devils_advocate],
        voters: [:pragmatist, :domain_expert],
        max_rounds: 3,
        consensus: :majority
      )

  ## Consensus policies

    - `:majority`      — more than 50% of voters score >= 6
    - `:supermajority` — 67%+ of voters score >= 6
    - `:unanimous`     — all voters score >= 6

  ## Result shape

      %{
        final_proposition:    String.t(),
        vote_tally:           %{voter_name => [round_score]},
        average_scores:       [float()],           # one per round that produced votes
        critique_log:         [{round, critic, critique}],
        convergence_history:  [float()],           # score deltas
        rounds_completed:     pos_integer(),
        consensus_reached:    boolean(),
        consensus_policy:     atom()
      }
  """

  require Logger

  alias OptimalSystemAgent.Conversations.Persona
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @default_max_rounds 3
  @convergence_threshold 0.05
  @passing_score 6

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @type debate_opts :: [
          proposition: String.t(),
          proposer: Persona.t() | atom() | map(),
          critics: [Persona.t() | atom() | map()],
          voters: [Persona.t() | atom() | map()],
          max_rounds: pos_integer(),
          consensus: :majority | :supermajority | :unanimous
        ]

  @doc """
  Run a structured debate to completion. Blocking call.

  Returns `{:ok, result_map}` when finished.
  """
  @spec start_debate(debate_opts()) :: {:ok, map()} | {:error, any()}
  def start_debate(opts) do
    proposition = Keyword.fetch!(opts, :proposition)
    proposer = opts |> Keyword.fetch!(:proposer) |> Persona.resolve()
    critics = opts |> Keyword.get(:critics, []) |> Enum.map(&Persona.resolve/1)
    voters = opts |> Keyword.get(:voters, []) |> Enum.map(&Persona.resolve/1)
    max_rounds = Keyword.get(opts, :max_rounds, @default_max_rounds)
    consensus_policy = Keyword.get(opts, :consensus, :majority)

    initial_state = %{
      proposition: proposition,
      current_proposition: proposition,
      proposer: proposer,
      critics: critics,
      voters: voters,
      max_rounds: max_rounds,
      consensus_policy: consensus_policy,
      round: 0,
      critique_log: [],
      vote_tally: build_empty_tally(voters),
      # Scores indexed by the round they were cast in: %{round => %{name => score}}.
      # `vote_tally` alone cannot express "this voter did not score THIS round",
      # which is what made `consensus_met?/1` count a stale score as current.
      round_votes: %{},
      average_scores: [],
      convergence_history: []
    }

    Logger.info(
      "[Debate] starting — proposition: #{inspect(proposition)} rounds=#{max_rounds} critics=#{length(critics)} voters=#{length(voters)}"
    )

    run_debate(initial_state)
  rescue
    e ->
      Logger.warning("[Debate] start_debate exception: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Round execution
  # ---------------------------------------------------------------------------

  defp run_debate(%{round: round, max_rounds: max} = state) when round >= max do
    finish(state)
  end

  defp run_debate(state) do
    round = state.round + 1

    Logger.debug("[Debate] round #{round}/#{state.max_rounds}")

    state = %{state | round: round}

    # Step 1: Proposer presents/revises
    state =
      case present_proposition(state) do
        {:ok, revised} ->
          Logger.debug("[Debate] proposer revised proposition (#{String.length(revised)} chars)")
          %{state | current_proposition: revised}

        {:error, _} ->
          state
      end

    # Step 2: Critics respond
    state = collect_critiques(state, round)

    # Step 3: Voters score
    {state, round_avg} = collect_votes(state, round)

    if is_nil(round_avg) do
      # Every voter failed this round. There is nothing to converge on and no
      # consensus to evaluate, so the round is discarded rather than scored.
      Logger.warning("[Debate] round #{round}: no voter produced a score — round discarded")
      run_debate(state)
    else
      evaluate_round(state, round, round_avg)
    end
  end

  defp evaluate_round(state, round, round_avg) do
    # Convergence check
    convergence_delta = compute_convergence(state.average_scores, round_avg)
    state = %{state | convergence_history: state.convergence_history ++ [convergence_delta]}

    Logger.debug(
      "[Debate] round #{round} avg_score=#{Float.round(round_avg, 2)} delta=#{Float.round(convergence_delta, 3)}"
    )

    cond do
      consensus_met?(state) ->
        Logger.info("[Debate] consensus reached at round #{round}")
        finish(state)

      round > 1 and convergence_delta < @convergence_threshold ->
        Logger.info(
          "[Debate] converged at round #{round} (delta #{convergence_delta} < #{@convergence_threshold})"
        )

        finish(state)

      true ->
        run_debate(state)
    end
  end

  defp finish(state) do
    result = %{
      final_proposition: state.current_proposition,
      vote_tally: state.vote_tally,
      average_scores: state.average_scores,
      critique_log: state.critique_log,
      convergence_history: state.convergence_history,
      rounds_completed: state.round,
      consensus_reached: consensus_met?(state),
      consensus_policy: state.consensus_policy
    }

    {:ok, result}
  end

  # ---------------------------------------------------------------------------
  # Proposer
  # ---------------------------------------------------------------------------

  defp present_proposition(state) do
    is_first_round = state.round == 1

    prompt =
      if is_first_round do
        """
        You are #{state.proposer.name} (#{state.proposer.role}).

        Present the following proposition clearly and compellingly.
        Cover: what you're proposing, why it matters, and how it would work.

        Proposition: #{state.proposition}

        Be concise (3-5 paragraphs). Do not include a preamble or sign-off.
        """
      else
        critique_summary = summarise_critiques(state.critique_log, state.round - 1)
        latest_scores = round_scores(state, state.round - 1)

        """
        You are #{state.proposer.name} (#{state.proposer.role}).

        You are revising your proposition based on round #{state.round - 1} critiques.

        Current proposition:
        #{state.current_proposition}

        Critiques received:
        #{critique_summary}

        Average score from voters: #{Float.round(List.last(state.average_scores, 0.0), 1)}/10
        #{format_voter_scores(latest_scores)}

        Revise the proposition to address the most valid criticisms.
        Be specific about what changed and why. Output the full revised proposition.
        """
      end

    messages = [%{role: "user", content: prompt}]
    system = Persona.system_prompt(state.proposer, state.proposition)
    opts = build_llm_opts(state.proposer, temperature: 0.6, max_tokens: 800)

    call_llm(messages, system, opts)
  end

  # ---------------------------------------------------------------------------
  # Critics
  # ---------------------------------------------------------------------------

  defp collect_critiques(state, round) do
    Enum.reduce(state.critics, state, fn critic, acc_state ->
      case critique_proposition(critic, acc_state, round) do
        {:ok, critique} ->
          entry = {round, critic.name, critique}
          %{acc_state | critique_log: acc_state.critique_log ++ [entry]}

        {:error, reason} ->
          Logger.warning("[Debate] critic #{critic.name} failed: #{inspect(reason)}")
          acc_state
      end
    end)
  end

  defp critique_proposition(critic, state, round) do
    prior_critiques =
      state.critique_log
      |> Enum.filter(fn {r, _, _} -> r == round - 1 end)
      |> Enum.map_join("\n", fn {_, c, text} -> "#{c}: #{String.slice(text, 0, 200)}" end)

    prompt = """
    You are #{critic.name} (#{critic.role}) in a structured debate.

    #{if prior_critiques != "", do: "Previous round critiques for context:\n#{prior_critiques}\n\n", else: ""}
    Current proposition (round #{round}):
    #{state.current_proposition}

    Provide a focused critique (2-3 paragraphs):
    1. What is the strongest weakness or risk?
    2. What assumption could break this?
    3. What would need to be true for this to succeed?

    Be specific and constructive. Do not simply agree or disagree — analyse.
    """

    messages = [%{role: "user", content: prompt}]
    system = Persona.system_prompt(critic, state.proposition)
    opts = build_llm_opts(critic, temperature: 0.7, max_tokens: 600)

    call_llm(messages, system, opts)
  end

  # ---------------------------------------------------------------------------
  # Voters
  # ---------------------------------------------------------------------------

  defp collect_votes(state, round) do
    critique_summary = summarise_critiques(state.critique_log, round)

    {updated_tally, this_round} =
      Enum.reduce(state.voters, {state.vote_tally, %{}}, fn voter, {tally, round_scores} ->
        case score_proposition(voter, state, round, critique_summary) do
          {:ok, score} ->
            voter_history = Map.get(tally, voter.name, [])
            new_tally = Map.put(tally, voter.name, voter_history ++ [score])
            {new_tally, Map.put(round_scores, voter.name, score)}

          {:error, reason} ->
            Logger.warning("[Debate] voter #{voter.name} failed: #{inspect(reason)}")
            {tally, round_scores}
        end
      end)

    scores = Map.values(this_round)

    # A round in which nobody scored has NO average. It used to record a
    # fabricated `0.0`, which then fed `compute_convergence/2` and
    # `List.last(average_scores)` as if the panel had unanimously rejected the
    # proposition. `nil` is propagated so the caller can discard the round
    # instead of drawing a conclusion from a number no voter produced.
    avg = if scores == [], do: nil, else: Enum.sum(scores) / length(scores)

    new_state = %{
      state
      | vote_tally: updated_tally,
        round_votes: Map.put(state.round_votes, round, this_round),
        average_scores: if(avg, do: state.average_scores ++ [avg], else: state.average_scores)
    }

    {new_state, avg}
  end

  defp score_proposition(voter, state, round, critique_summary) do
    prompt = """
    You are #{voter.name} (#{voter.role}) scoring a proposition.

    Proposition (round #{round}):
    #{state.current_proposition}

    Critiques this round:
    #{critique_summary}

    Score this proposition on a scale of 0-10:
    - 0-3: Fundamentally flawed, not viable
    - 4-5: Significant issues, needs major rework
    - 6-7: Viable with caveats, worth pursuing carefully
    - 8-9: Strong proposition, minor concerns only
    - 10: Excellent, ready to proceed

    Respond ONLY with a JSON object:
    {"score": <integer 0-10>, "rationale": "<one sentence>"}
    """

    messages = [%{role: "user", content: prompt}]
    system = Persona.system_prompt(voter, state.proposition)
    opts = build_llm_opts(voter, temperature: 0.2, max_tokens: 150)

    case call_llm(messages, system, opts) do
      {:ok, raw} -> parse_score(raw)
      error -> error
    end
  end

  @doc false
  def parse_score(raw) do
    cleaned =
      raw
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"score" => score}} when is_integer(score) and score >= 0 and score <= 10 ->
        {:ok, score}

      {:ok, %{"score" => score}} when is_number(score) ->
        {:ok, round(score)}

      _ ->
        # Fall back to a number the model actually LABELLED as a score.
        #
        # The old fallback was `~r/\b([0-9]|10)\b/` over the raw text — the
        # first standalone digit anywhere in the reply. "Evaluated against the
        # 3 criteria" scored 3; "I have 0 objections" scored 0. A vote invented
        # from arbitrary prose is worse than a failed vote, because
        # `consensus_met?/1` treats it as a real ballot.
        case Regex.run(~r/\bscores?\b\D{0,20}?\b(10|[0-9])\b/i, raw) do
          [_, n] -> {:ok, String.to_integer(n)}
          _ -> {:error, :parse_failed}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Consensus
  # ---------------------------------------------------------------------------

  # Consensus is a statement about the CURRENT round.
  #
  # This used to read `List.last(scores)` out of the whole `vote_tally`, which
  # for a voter that failed this round is last round's number — and it counted
  # that voter in `voter_count` too. An entire final round of failed voters
  # therefore reported `consensus_reached: true` from scores nobody cast in it.
  # Only scores actually recorded for `round` count, on both sides of the ratio.
  @doc false
  def consensus_met?(%{round_votes: round_votes, consensus_policy: policy, round: round}) do
    scores = Map.get(round_votes, round, %{})

    if round == 0 or map_size(scores) == 0 do
      false
    else
      voter_count = map_size(scores)

      passing_voters =
        Enum.count(scores, fn {_name, score} -> score >= @passing_score end)

      case policy do
        :majority -> passing_voters > voter_count / 2
        :supermajority -> passing_voters >= voter_count * 0.67
        :unanimous -> passing_voters == voter_count
        _ -> passing_voters > voter_count / 2
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp compute_convergence([], _new_avg), do: 1.0

  defp compute_convergence(history, new_avg) do
    prev_avg = List.last(history, 0.0)
    abs(new_avg - prev_avg) / max(prev_avg, 0.01)
  end

  defp build_empty_tally(voters) do
    Map.new(voters, fn v -> {v.name, []} end)
  end

  defp summarise_critiques(critique_log, round) do
    critique_log
    |> Enum.filter(fn {r, _, _} -> r == round end)
    |> Enum.map_join("\n\n", fn {_, critic, text} -> "#{critic}:\n#{text}" end)
  end

  # Scores cast in a SPECIFIC round. Callers must say which: the proposer's
  # revision prompt wants the previous round's numbers, and the current round has
  # not voted yet when that prompt is built.
  defp round_scores(state, round) do
    state.round_votes
    |> Map.get(round, %{})
    |> Enum.to_list()
  end

  defp format_voter_scores([]), do: ""

  defp format_voter_scores(scores) do
    scores
    |> Enum.map_join(", ", fn {name, score} -> "#{name}: #{score}/10" end)
  end

  defp call_llm(messages, system, opts) do
    opts = Keyword.put(opts, :system, system)

    case Providers.chat(messages, opts) do
      {:ok, %{content: content}} -> {:ok, content}
      {:ok, content} when is_binary(content) -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_llm_opts(%Persona{model: nil}, extra), do: extra
  defp build_llm_opts(%Persona{model: model}, extra), do: Keyword.put(extra, :model, model)
end
