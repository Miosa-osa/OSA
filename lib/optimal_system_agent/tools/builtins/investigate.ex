defmodule OptimalSystemAgent.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool — adversarial dual-prompt architecture.

  EVIDENCE QUALITY PIPELINE: Paper type classification + evidence hierarchy scoring.
  Every citation is verified against paper abstracts AND classified by type
  (systematic review, RCT, observational study, other).

  Scores come from: verification status * evidence hierarchy weight * citation bonus.
  - Systematic reviews/meta-analyses score 3x
  - RCTs/experiments score 2x
  - Observational studies score 1.5x
  - Unclassified score 1x

  PAPER-FIRST DESIGN: Runs THREE parallel paper search pairs (FOR, AGAINST, and
  SYSTEMATIC REVIEWS), then feeds merged papers to TWO adversarial LLM prompts.

  Multi-source literature search: Semantic Scholar + OpenAlex + alphaXiv.
  Uses vaos-ledger's Literature module for Semantic Scholar and OpenAlex,
  with alphaXiv MCP for embedding-based arXiv search.

  AEC TWO-STORE ARCHITECTURE (arxiv.org/abs/2602.03974):
  Evidence is classified into two stores based on source quality:
  - Grounded store: high-quality sources (major journals, high citations) — determines verdict
  - Belief store: low-quality sources (predatory journals, niche) — context only, cannot flip direction
  This prevents the homeopathy problem where niche journals outvote established science.

  ACE PATTERN (Agentic Context Engineering):
  - Helpful/Harmful counters on evidence triples in the knowledge graph
  - Compound loop fetches prior EVIDENCE, not prior conclusions
  """

  require Logger

  @behaviour MiosaTools.Behaviour

  alias MiosaProviders.Registry, as: Providers
  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger
  alias Vaos.Ledger.Epistemic.Models
  alias Vaos.Ledger.Research.Literature
  alias Vaos.Ledger.Epistemic.Policy
  alias Vaos.Ledger.Research.Pipeline
  alias Vaos.Ledger.ML.CrashLearner

  @ledger_path Path.join(System.user_home!(), ".openclaw/investigate_ledger.json")
  @ledger_name :investigate_ledger

  @stop_words ~w(the a an is are was were be been being have has had do does did
    will would shall should may might must can could of in to for with on at by
    from as into through during before after above below between out off over
    under again further then once here there when where why how all both each
    few more most other some such no nor not only own same so than too very it
    its this that these those and but or if while)

  # AEC Two-Store Architecture (arxiv.org/abs/2602.03974)
  # Grounded store: high-quality sources that can determine the verdict
  # Belief store: low-quality sources for context only (cannot flip direction)
  @grounded_threshold 0.4

  # Word-boundary patterns to avoid false positives on common words like "cell", "nature", "science"
  @high_quality_pattern_sources [
    {~S"\bnature\b(?!\s+of\b)", "i"},
    {~S"(?<!\bcomputer\s)(?<!\bdata\s)\bscience\b(?!\s+of\b|\s+fiction\b)", "i"},
    {~S"\blancet\b", "i"},
    {~S"\bbmj\b", "i"},
    {~S"\bnejm\b", "i"},
    {~S"\bcochrane\b", "i"},
    {~S"\bjama\b", "i"},
    {~S"\bplos\b", "i"},
    {~S"\bcell\s+(press|reports|research|biology|metabolism|host|systems|stem|chemical)\b", "i"},
    {~S"\bannual\s+review", "i"},
    {~S"\bpnas\b", "i"},
    {~S"\bwiley\b", "i"},
    {~S"\bspringer\b", "i"},
    {~S"\belsevier\b", "i"},
    {~S"\boxford\s+(university|academic|press)", "i"},
    {~S"\bcambridge\s+(university|press)", "i"},
    {~S"\bieee\b", "i"},
    {~S"\bacm\b", "i"},
    {~S"\bamerican\s+medical", "i"},
    {~S"\bamerican\s+psychological", "i"},
    {~S"\bbritish\s+medical", "i"},
    {~S"\bworld\s+health", "i"}
  ]

  # Low-quality JOURNAL/SOURCE patterns — matched ONLY against source/journal field.
  # Do NOT add topic terms here (e.g. "homeopath") — they'll match every paper's
  # title/abstract when investigating that topic, nuking all source quality scores.
  @low_quality_journal_sources [
    {~S"journal.of.alternative", "i"},
    {~S"complementary.*medicine", "i"},
    {~S"integrative.*medicine", "i"},
    {~S"traditional.*medicine", "i"},
    {~S"holistic.*medicine", "i"},
    {~S"journal.*healing", "i"},
    {~S"explore.*journal", "i"},
    {~S"frontier.*alternative", "i"},
    {~S"evidence.based.complementary", "i"},
    {~S"homeopath.*journal", "i"},
    {~S"journal.*homeopath", "i"},
    {~S"journal.*naturopath", "i"},
    {~S"journal.*ayurved", "i"}
  ]

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "investigate"

  @impl true
  def description do
    "Investigate a claim or topic: runs multi-source paper search (Semantic Scholar + OpenAlex + alphaXiv, " <>
      "FOR, AGAINST, and REVIEWS), then dual adversarial LLM analysis with citation verification " <>
      "and evidence hierarchy scoring (review > trial > study > other)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "topic" => %{
          "type" => "string",
          "description" => "The claim or topic to investigate"
        },
        "depth" => %{
          "type" => "string",
          "enum" => ["standard", "deep"],
          "description" => "standard = adversarial debate + citation verification; deep = standard + research pipeline (hypotheses, testing, report)"
        }
      },
      "required" => ["topic"]
    }
  end

  @impl true
  def execute(args) do
    topic = Map.get(args, "topic") || ""
    depth = Map.get(args, "depth") || "standard"

    topic = String.trim(to_string(topic))

    if topic == "" do
      {:error, "Missing topic"}
    else
      run_investigation(topic, depth)
    end
  end

  # -- Main pipeline ---------------------------------------------------

  defp run_investigation(topic, depth) do
    :inets.start()
    :ssl.start()

    # Start alphaXiv MCP in an unlinked process — the MCP client crash-loops
    # on auth failure (401) and sends EXIT to linked callers, killing the pipeline.
    # Trap exits for the duration of the start, then restore.
    old_trap = Process.flag(:trap_exit, true)
    try do
      OptimalSystemAgent.Tools.Builtins.AlphaXivClient.start_link()
      # Drain any immediate EXIT from the MCP client crashing during handshake
      receive do
        {:EXIT, _pid, reason} ->
          Logger.warning("[investigate] alphaXiv MCP crashed during init: #{inspect(reason)}")
      after
        2_000 -> :ok
      end
    catch
      :exit, reason ->
        Logger.warning("[investigate] alphaXiv MCP unavailable: #{inspect(reason)}")
    after
      Process.flag(:trap_exit, old_trap)
    end

    # 0. Create scorer cache ETS table upfront (owned by caller, visible to child tasks)
    ensure_scorer_cache()

    # 1. Start the real epistemic ledger GenServer
    ensure_ledger_started()

    # 1a. Start CrashLearner if not running
    case CrashLearner.start_link(name: :osa_crash_learner) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end

    # 2. Extract keywords for prior knowledge search
    keywords = extract_keywords(topic)

    # 3. Prior knowledge search — fetch prior EVIDENCE, not conclusions
    case ensure_store_started() do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[investigate] Knowledge store unavailable: #{inspect(reason)}")
    end
    store = store_ref()
    prior_evidence = fetch_prior_evidence_by_keywords(store, keywords)

    # 4. MULTI-SOURCE PAPER SEARCH: Semantic Scholar + OpenAlex + alphaXiv (parallel)
    #    Uses extracted keywords to augment queries for better relevance
    {all_papers, source_counts} = search_all_papers(topic, keywords)

    Logger.info("[investigate] Papers: #{length(all_papers)} total (#{inspect(source_counts)})")

    # 5. Format papers context for LLM prompts
    papers_context = format_papers(all_papers)

    # 6. Prior evidence context (evidence only, no conclusions)
    prior_text = if prior_evidence == [] do
      ""
    else
      "\n\nPreviously investigated evidence on related topics:\n" <>
        Enum.join(prior_evidence, "\n") <> "\n"
    end

    # 6a. Fetch known failure pitfalls from CrashLearner
    pitfalls = try do
      {:ok, plist} = CrashLearner.get_pitfalls(:osa_crash_learner)
      plist
    rescue
      _ -> []
    end

    pitfall_context = if pitfalls != [] do
      text = Enum.map(pitfalls, fn p -> "- #{p.summary}" end) |> Enum.join("
")
      "

Known failure patterns to avoid:
#{text}
"
    else
      ""
    end

    # 7. TWO ADVERSARIAL LLM CALLS (sequential for rate-limit safety)
    example_format = """
    Example of correct format:
    1. [SOURCED] (strength: 8) A meta-analysis of 12 RCTs found significant effects (p<0.05) with moderate effect sizes across multiple conditions. [Paper 3] specifically analyzed 500 patients and found a 23% improvement rate over placebo, suggesting robust clinical benefit.
    2. [REASONING] (strength: 5) The mechanism of action is biologically plausible because...
    """

    for_prompt = """
    You are a researcher who genuinely believes the following claim is TRUE.
    Using the papers provided and your knowledge, make the STRONGEST possible case.

    Claim: #{topic}

    #{papers_context}
    #{prior_text}

    Present your 3-5 strongest arguments. For each argument:
    - Write a FULL paragraph (2-4 sentences minimum) explaining the evidence
    - Cite a specific paper as [Paper N] within your paragraph text
    - Rate the argument strength 1-10
    - Tag as [SOURCED] if backed by a paper, [REASONING] if from your analysis
    - Do NOT just write a title — write a substantive argument with evidence

    #{example_format}

    Now write your arguments:
    1. [SOURCED/REASONING] (strength: N) Your detailed argument here [Paper N if applicable]
    """

    against_prompt = """
    You are a researcher who genuinely believes the following claim is FALSE.
    Using the papers provided and your knowledge, make the STRONGEST possible case AGAINST it.

    Claim: #{topic}

    #{papers_context}
    #{prior_text}

    Present your 3-5 strongest counterarguments. For each argument:
    - Write a FULL paragraph (2-4 sentences minimum) explaining the evidence
    - Cite a specific paper as [Paper N] within your paragraph text
    - Rate the argument strength 1-10
    - Tag as [SOURCED] if backed by a paper, [REASONING] if from your analysis
    - Do NOT just write a title — write a substantive argument with evidence

    #{example_format}

    Now write your counterarguments:
    1. [SOURCED/REASONING] (strength: N) Your detailed counterargument here [Paper N if applicable]
    """

    for_messages = [
      %{role: "system", content: "You are an intellectually honest researcher making the strongest case FOR a claim. Vary your strength ratings — not every argument is equally strong." <> pitfall_context},
      %{role: "user", content: for_prompt}
    ]

    against_messages = [
      %{role: "system", content: "You are an intellectually honest researcher making the strongest case AGAINST a claim. Vary your strength ratings — not every argument is equally strong." <> pitfall_context},
      %{role: "user", content: against_prompt}
    ]

    model = Application.get_env(:optimal_system_agent, :utility_model)
    llm_opts = [temperature: 0.1, max_tokens: 8192]
    llm_opts = if model, do: Keyword.put(llm_opts, :model, model), else: llm_opts

    # Run advocates sequentially — concurrent calls trigger rate limits on some
    # providers (Zhipu/GLM), and reasoning models need generous timeouts.
    for_result = Providers.chat(for_messages, llm_opts)
    against_result = Providers.chat(against_messages, llm_opts)

    # 8. Parse both sides
    supporting = case for_result do
      {:ok, %{content: response}} when is_binary(response) and response != "" ->
        parse_adversarial_evidence(response)
      {:ok, %{content: ""}} ->
        Logger.warning("[investigate] FOR-side LLM returned empty content (reasoning model token exhaustion?)")
        []
      {:error, reason} ->
        Logger.warning("[investigate] FOR-side LLM call failed: #{inspect(reason)}")
        try do
          CrashLearner.report_crash(:osa_crash_learner, "investigate_for_#{short_hash(topic)}", inspect(reason), nil, %{topic: topic, side: "for", papers_count: length(all_papers)})
        rescue
          _ -> :ok
        end
        []
      _ ->
        Logger.warning("[investigate] FOR-side LLM call failed")
        []
    end

    opposing = case against_result do
      {:ok, %{content: response}} when is_binary(response) and response != "" ->
        parse_adversarial_evidence(response)
      {:ok, %{content: ""}} ->
        Logger.warning("[investigate] AGAINST-side LLM returned empty content (reasoning model token exhaustion?)")
        []
      {:error, reason} ->
        Logger.warning("[investigate] AGAINST-side LLM call failed: #{inspect(reason)}")
        try do
          CrashLearner.report_crash(:osa_crash_learner, "investigate_against_#{short_hash(topic)}", inspect(reason), nil, %{topic: topic, side: "against", papers_count: length(all_papers)})
        rescue
          _ -> :ok
        end
        []
      _ ->
        Logger.warning("[investigate] AGAINST-side LLM call failed")
        []
    end

    # 8a. Build paper map for citation verification
    paper_map = all_papers
      |> Enum.with_index(1)
      |> Map.new(fn {p, i} -> {i, p} end)

    # 8b. Handle partial results honestly
    cond do
      supporting == [] and opposing == [] ->
        {:error, "Both adversarial LLM calls failed"}

      supporting == [] ->
        # Only AGAINST succeeded — verify what we have
        verified_opposing = verify_citations(opposing, paper_map)
        result = "## Investigation: #{topic}\n\n" <>
          "**Status: PARTIAL** -- Only the case AGAINST was analyzed (FOR advocate failed)\n" <>
          "**Cannot determine direction from one-sided analysis**\n\n" <>
          format_verified_evidence(verified_opposing, "Case Against") <>
          "\n\n### Papers Consulted\n" <> format_paper_list(all_papers)
        {:ok, result}

      opposing == [] ->
        # Only FOR succeeded — verify what we have
        verified_supporting = verify_citations(supporting, paper_map)
        result = "## Investigation: #{topic}\n\n" <>
          "**Status: PARTIAL** -- Only the case FOR was analyzed (AGAINST advocate failed)\n" <>
          "**Cannot determine direction from one-sided analysis**\n\n" <>
          format_verified_evidence(verified_supporting, "Case For") <>
          "\n\n### Papers Consulted\n" <> format_paper_list(all_papers)
        {:ok, result}

      true ->
        # Both succeeded — full analysis with citation verification
        run_full_analysis(topic, supporting, opposing, all_papers, paper_map,
                          source_counts, keywords, prior_evidence, store, depth)
    end
  rescue
    e ->
      Logger.error("[investigate] Investigation failed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
      {:error, "Investigation failed: " <> Exception.message(e)}
  end

  # -- Full analysis (both sides succeeded) ------------------------------

  defp run_full_analysis(topic, supporting_raw, opposing_raw, all_papers, paper_map,
                         source_counts, keywords, prior_evidence, store, depth) do
    # 9. CITATION VERIFICATION + PAPER TYPE CLASSIFICATION — the evidence quality step
    verified_supporting = verify_citations(supporting_raw, paper_map)
    verified_opposing = verify_citations(opposing_raw, paper_map)

    # 9a. AEC TWO-STORE CLASSIFICATION (arxiv.org/abs/2602.03974)
    # Split into grounded (high-quality, determines verdict) and belief (context only)
    classified_supporting = classify_evidence_store(verified_supporting, paper_map)
    classified_opposing = classify_evidence_store(verified_opposing, paper_map)

    grounded_for = Enum.filter(classified_supporting, & &1.evidence_store == :grounded)
    grounded_against = Enum.filter(classified_opposing, & &1.evidence_store == :grounded)

    grounded_for_count = length(grounded_for)
    grounded_against_count = length(grounded_against)
    belief_for_count = length(classified_supporting) - grounded_for_count
    belief_against_count = length(classified_opposing) - grounded_against_count

    # 10. Compute direction from GROUNDED evidence only (AEC commitment gating)
    verified_for = Enum.count(classified_supporting, & &1.verified)
    verified_against = Enum.count(classified_opposing, & &1.verified)

    grounded_for_score = Enum.sum(Enum.map(grounded_for, & &1.score))
    grounded_against_score = Enum.sum(Enum.map(grounded_against, & &1.score))
    total_for_score = Enum.sum(Enum.map(classified_supporting, & &1.score))
    total_against_score = Enum.sum(Enum.map(classified_opposing, & &1.score))

    for_total = total_for_score
    against_total = total_against_score

    # Direction uses grounded scores first (AEC commitment gating).
    # When grounded store is empty, falls back to belief-store consensus
    # (prefixed with "belief_") to avoid always returning "insufficient".
    direction = cond do
      # Both stores have grounded evidence — use grounded scores
      grounded_for_score > 0 and grounded_against_score > 0 ->
        cond do
          grounded_for_score > grounded_against_score * 1.3 -> "supporting"
          grounded_against_score > grounded_for_score * 1.3 -> "opposing"
          true -> "genuinely_contested"
        end

      # Asymmetric grounded evidence
      grounded_against_score == 0 and grounded_for_score > 0 ->
        "asymmetric_evidence_for"
      grounded_for_score == 0 and grounded_against_score > 0 ->
        "asymmetric_evidence_against"

      # No grounded evidence at all — fall back to belief store
      # This prevents the system from being permanently stuck on "insufficient"
      # when source quality thresholds filter out all papers
      for_total == 0 and against_total == 0 ->
        "insufficient_evidence"
      against_total > for_total * 1.5 ->
        "belief_consensus_against"
      for_total > against_total * 1.5 ->
        "belief_consensus_for"
      true ->
        "belief_contested"
    end

    # Rebind for downstream compatibility (classified versions are supersets)
    verified_supporting = classified_supporting
    verified_opposing = classified_opposing

    # Count fraudulent citations
    fraudulent_count = Enum.count(verified_supporting ++ verified_opposing,
      fn ev -> ev.verification == "unverified" end)

    reasoning_for = Enum.count(verified_supporting,
      fn ev -> ev.verification == "no_citation" end)
    reasoning_against = Enum.count(verified_opposing,
      fn ev -> ev.verification == "no_citation" end)

    # Count paper types across all evidence
    all_evidence = verified_supporting ++ verified_opposing
    review_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :review end)
    trial_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :trial end)
    study_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :study end)

    # 11. Create claim and add evidence to ledger
    claim = EpistemicLedger.add_claim(
      [title: String.slice(topic, 0, 100), statement: topic, tags: ["investigate", "auto", "adversarial"]],
      @ledger_name
    )

    # Add FOR arguments as supporting evidence (using hierarchy-weighted score)
    supporting_records = add_evidence_to_ledger(verified_supporting, claim, :support)

    # Add AGAINST arguments as BOTH attacks AND contradicting evidence
    _contra_records = add_evidence_to_ledger(verified_opposing, claim, :contradict)
    opposing_records = add_attacks_to_ledger(verified_opposing, claim)

    # Refresh claim to recompute metrics
    EpistemicLedger.refresh_claim(claim.id, @ledger_name)

    # Get ledger metrics for supplementary display
    metrics = EpistemicLedger.claim_metrics(claim.id, @ledger_name)
    belief = metrics["belief"]
    uncertainty = metrics["uncertainty"]

    # 12. Persist ledger to disk
    EpistemicLedger.save(@ledger_name)

    # 13. Store in knowledge graph
    topic_id = "investigate:" <> short_hash(topic)
    claim_id = claim.id

    json_result = Jason.encode!(%{
      topic: topic,
      claim_id: claim_id,
      direction: direction,
      verified_for: verified_for,
      verified_against: verified_against,
      reasoning_for: reasoning_for,
      reasoning_against: reasoning_against,
      for_score: Float.round(for_total * 1.0, 3),
      against_score: Float.round(against_total * 1.0, 3),
      grounded_for_score: Float.round(grounded_for_score * 1.0, 3),
      grounded_against_score: Float.round(grounded_against_score * 1.0, 3),
      grounded_for_count: grounded_for_count,
      grounded_against_count: grounded_against_count,
      belief_for_count: belief_for_count,
      belief_against_count: belief_against_count,
      aec_methodology: "arxiv.org/abs/2602.03974",
      fraudulent_citations: fraudulent_count,
      belief: Float.round(belief * 1.0, 3),
      uncertainty: Float.round(uncertainty * 1.0, 3),
      evidence_quality: %{
        reviews: review_count,
        trials: trial_count,
        studies: study_count
      },
      supporting: Enum.map(verified_supporting, fn ev ->
        %{summary: ev.summary, score: ev.score, verified: ev.verified,
          verification: ev.verification, paper_type: Atom.to_string(ev.paper_type),
          citation_count: ev.citation_count, strength_display: ev.strength,
          source_quality: Map.get(ev, :source_quality, 0),
          evidence_store: Atom.to_string(Map.get(ev, :evidence_store, :unknown))}
      end),
      opposing: Enum.map(verified_opposing, fn ev ->
        %{summary: ev.summary, score: ev.score, verified: ev.verified,
          verification: ev.verification, paper_type: Atom.to_string(ev.paper_type),
          citation_count: ev.citation_count, strength_display: ev.strength,
          source_quality: Map.get(ev, :source_quality, 0),
          evidence_store: Atom.to_string(Map.get(ev, :evidence_store, :unknown))}
      end),
      papers_found: length(all_papers),
      source_counts: source_counts,
      papers_detail: Enum.map(all_papers, fn p ->
        %{title: p["title"], year: p["year"],
          citations: p["citation_count"] || p["citationCount"] || 0,
          source: p["source"] || "unknown"}
      end),
      investigation_id: topic_id,
      suggested_next: try do
        Policy.rank_actions(@ledger_name, limit: 3)
        |> Enum.map(fn a ->
          %{action_type: a.action_type, claim_title: a.claim_title,
            information_gain: a.expected_information_gain, claim_id: a.claim_id,
            reason: a.reason}
        end)
      rescue
        _ -> []
      end
    })

    triples = [
      {topic_id, "rdf:type", "vaos:Investigation"},
      {topic_id, "vaos:topic", topic},
      {topic_id, "vaos:direction", direction},
      {topic_id, "vaos:verified_for", Integer.to_string(verified_for)},
      {topic_id, "vaos:verified_against", Integer.to_string(verified_against)},
      {topic_id, "vaos:fraudulent_citations", Integer.to_string(fraudulent_count)},
      {topic_id, "vaos:json_result", json_result},
      {topic_id, "vaos:claim_id", claim_id},
      {topic_id, "vaos:timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
    ]

    keyword_triples = Enum.map(keywords, fn kw ->
      {topic_id, "vaos:keyword", kw}
    end)

    for triple <- triples ++ keyword_triples do
      MiosaKnowledge.assert(store, triple)
    end

    # Store helpful/harmful counters for supporting evidence
    Enum.each(supporting_records, fn ev ->
      ev_id = "evidence:" <> ev.id
      MiosaKnowledge.assert(store, {topic_id, "vaos:has_evidence", ev_id})
      MiosaKnowledge.assert(store, {ev_id, "vaos:helpful_count", "0"})
      MiosaKnowledge.assert(store, {ev_id, "vaos:harmful_count", "0"})
      MiosaKnowledge.assert(store, {ev_id, "vaos:summary", ev.summary})
    end)

    # Store attack records in knowledge graph
    Enum.each(opposing_records, fn atk ->
      atk_id = "attack:" <> atk.id
      MiosaKnowledge.assert(store, {topic_id, "vaos:has_attack", atk_id})
      MiosaKnowledge.assert(store, {atk_id, "vaos:helpful_count", "0"})
      MiosaKnowledge.assert(store, {atk_id, "vaos:harmful_count", "0"})
      MiosaKnowledge.assert(store, {atk_id, "vaos:summary", atk.description})
    end)

    # Increment helpful counters for prior evidence that was independently regenerated
    increment_helpful_for_reused_evidence(store, prior_evidence, verified_supporting ++ verified_opposing)

    # 13a. OWL Reasoner bridge — materialize inferred triples and check for contradictions
    try do
      case MiosaKnowledge.Reasoner.materialize(store) do
        {:ok, rounds} when rounds > 0 ->
          Logger.info("[investigate] OWL reasoner ran #{rounds} fixpoint round(s), inferred new triples")
          # Check if any inferred contradictions relate to our investigation
          case MiosaKnowledge.sparql(store,
            "SELECT ?s ?p ?o WHERE { ?s vaos:contradicts ?o }") do
            {:ok, results} when is_list(results) and results != [] ->
              for r <- results do
                Logger.info("[investigate] OWL-visible contradiction: #{r["s"]} contradicts #{r["o"]}")
              end
            _ -> :ok
          end
        {:ok, 0} ->
          Logger.debug("[investigate] OWL reasoner: no new inferences")
        _ -> :ok
      end
    rescue
      e -> Logger.warning("[investigate] OWL reasoner failed: #{Exception.message(e)}")
    end

    # 14. Cross-investigation contradiction detection
    conflicts = detect_contradictions(store, topic_id, direction, keywords)
    conflict_note = if conflicts == [] do
      ""
    else
      conflict_lines = Enum.map(conflicts, fn c ->
        "  - #{c.prior_topic} (#{c.prior_id}): #{c.prior_direction} vs current #{direction}"
      end)
      "\n### Cross-Investigation Conflicts\n" <> Enum.join(conflict_lines, "\n") <> "\n"
    end

    # 15. Assess advocacy quality (flag unreliable advocates)
    quality_note = assess_advocacy_quality(verified_supporting, verified_opposing)

    # 15a. Check uncertainty and suggest iteration
    iteration_note = maybe_suggest_iteration(claim, @ledger_name)

    # 15b. Deep mode: run research pipeline if requested
    deep_note = if depth == "deep" do
      deep_research_note(topic, claim, all_papers, store)
    else
      ""
    end

    # 16. Format result with verification status and evidence quality
    for_arguments = format_verified_evidence(verified_supporting, "Case For (grounded: #{Float.round(grounded_for_score * 1.0, 2)}, total: #{Float.round(for_total * 1.0, 2)})")
    against_arguments = format_verified_evidence(verified_opposing, "Case Against (grounded: #{Float.round(grounded_against_score * 1.0, 2)}, total: #{Float.round(against_total * 1.0, 2)})")

    paper_list = format_paper_list(all_papers)

    result =
      "## Investigation: #{topic}\n\n" <>
      "**Direction: #{direction}** (AEC grounded-only verdict)\n" <>
      "**Grounded score: #{Float.round(grounded_for_score * 1.0, 2)} for vs #{Float.round(grounded_against_score * 1.0, 2)} against**\n" <>
      "**Total score (incl. belief): #{Float.round(for_total * 1.0, 2)} for vs #{Float.round(against_total * 1.0, 2)} against**\n" <>
      "**Evidence stores: #{grounded_for_count + grounded_against_count} grounded, #{belief_for_count + belief_against_count} belief**\n" <>
      "**Verified citations for: #{verified_for} | Verified citations against: #{verified_against}**\n" <>
      "**Fraudulent citations detected: #{fraudulent_count}**\n" <>
      "**Evidence quality: #{review_count} reviews, #{trial_count} trials, #{study_count} studies**\n" <>

      "**Ledger belief: #{Float.round(belief * 1.0, 3)}, uncertainty: #{Float.round(uncertainty * 1.0, 3)}**\n" <>
      "**Papers found:** #{length(all_papers)} (#{format_source_counts(source_counts)})\n\n" <>
      (if quality_note != "", do: quality_note <> "\n\n", else: "") <>
      "### #{for_arguments}\n\n" <>
      "### #{against_arguments}\n\n" <>
      "### Papers Consulted\n#{paper_list}\n" <>
      conflict_note <>
      (if prior_evidence != [], do: "\n### Prior Evidence (related topics)\n" <> Enum.join(prior_evidence, "\n") <> "\n", else: "") <>
      deep_note <>
      iteration_note <>
      "\n### Keywords\n  " <> Enum.join(keywords, ", ") <> "\n\n" <>
      "*Claim ID: #{claim_id} -- stored in knowledge graph as #{topic_id}*" <>
      "\n\n<!-- VAOS_JSON:#{json_result} -->"

    # 16. Policy — suggest next investigations based on information gain
    next_actions_text = try do
      next_actions = Policy.rank_actions(Process.whereis(@ledger_name), limit: 5)
      if next_actions != [] do
        suggestions = next_actions
          |> Enum.with_index(1)
          |> Enum.map(fn {action, i} ->
            gain_str = Float.round(action.expected_information_gain, 2) |> to_string()
            "  #{i}. #{action.action_type}: \"#{action.claim_title}\" (gain: #{gain_str}) — #{action.reason}"
          end)
          |> Enum.join("
")
        "

### Suggested Next Investigations
" <>
          "Based on where uncertainty is highest in the knowledge graph:
" <> suggestions
      else
        ""
      end
    rescue
      e ->
        Logger.warning("[investigate] Policy.rank_actions failed: #{Exception.message(e)}")
        ""
    end

    result = result <> next_actions_text

    {:ok, result}
  end

  # -- Citation Verification + Paper Type Classification ------------------

  defp verify_citations(evidence_list, paper_map) do
    # Split into items that need LLM verification and those that don't
    {need_llm, no_llm} = Enum.split_with(evidence_list, fn ev ->
      case extract_paper_ref(ev.summary) do
        nil -> false
        n -> Map.has_key?(paper_map, n)
      end
    end)

    # Handle non-LLM items immediately
    no_llm_verified = Enum.map(no_llm, fn ev ->
      case extract_paper_ref(ev.summary) do
        nil -> %{ev | verified: false, verification: "no_citation", paper_type: :reasoning, citation_count: 0, score: 0.15}
        _n -> %{ev | verified: false, verification: "invalid_ref", paper_type: :other, citation_count: 0, score: 0.0}
      end
    end)

    # Run LLM verification sequentially — reasoning models (GLM-4.7) are slow
    # and rate-limited, concurrent calls all fail or timeout
    llm_verified = Enum.map(need_llm, fn ev ->
      paper_num = extract_paper_ref(ev.summary)
      paper = Map.get(paper_map, paper_num)
      citation_count = paper["citation_count"] || paper["citationCount"] || 0

      case cached_verify(ev, paper) do
        {verification, paper_type} ->
          score = compute_evidence_score(verification, paper_type, citation_count)
          verified = verification in [:verified, :partial]
          verification_str = Atom.to_string(verification)
          %{ev | verified: verified, verification: verification_str, paper_type: paper_type, citation_count: citation_count, score: score}
      end
    end)

    # Recombine in original order by matching on summary
    original_order = Enum.map(evidence_list, fn ev ->
      Enum.find(llm_verified ++ no_llm_verified, fn v -> v.summary == ev.summary end) || ev
    end)

    original_order
  end

  defp extract_paper_ref(summary) do
    case Regex.run(~r/\[Paper (\d+)\]/, summary) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end

  defp verify_single_citation(evidence, paper) do
    abstract = Map.get(paper, "abstract", "") || ""
    title = Map.get(paper, "title", "") || ""

    prompt = """
    Paper title: #{title}
    Paper abstract: #{String.slice(to_string(abstract), 0, 500)}

    Claim: #{evidence.summary}

    Two questions:
    1. Does this paper's abstract support the specific claim? VERIFIED / PARTIAL / UNVERIFIED
    2. Paper type? REVIEW (systematic review/meta-analysis), TRIAL (RCT/experiment), STUDY (observational/single study), OTHER

    Answer format: WORD WORD (e.g., VERIFIED REVIEW or UNVERIFIED STUDY)
    """

    messages = [%{role: "user", content: prompt}]

    model = Application.get_env(:optimal_system_agent, :utility_model)
    verify_opts = [temperature: 0.0, max_tokens: 4096]
    verify_opts = if model, do: Keyword.put(verify_opts, :model, model), else: verify_opts

    case Providers.chat(messages, verify_opts) do
      {:ok, %{content: response}} when is_binary(response) and response != "" ->
        response_clean = String.trim(response) |> String.upcase()

        verification = cond do
          String.contains?(response_clean, "UNVERIFIED") -> :unverified
          String.contains?(response_clean, "PARTIAL") -> :partial
          String.contains?(response_clean, "VERIFIED") -> :verified
          true -> :unverified
        end

        paper_type = cond do
          String.contains?(response_clean, "REVIEW") -> :review
          String.contains?(response_clean, "TRIAL") -> :trial
          String.contains?(response_clean, "STUDY") -> :study
          true -> :other
        end

        {verification, paper_type}
      {:ok, %{content: ""}} ->
        Logger.warning("[investigate] verify_citation: empty content (reasoning model token exhaustion)")
        {:unverified, :other}
      {:error, reason} ->
        Logger.warning("[investigate] verify_citation failed: #{inspect(reason)}")
        {:unverified, :other}
      other ->
        Logger.warning("[investigate] verify_citation unexpected: #{inspect(other) |> String.slice(0, 200)}")
        {:unverified, :other}
    end
  end

  # -- Evidence hierarchy scoring -----------------------------------------

  defp compute_evidence_score(verification, paper_type, citation_count) do
    # Base score from verification
    base = case verification do
      :verified -> 1.0
      :partial -> 0.5
      :unverified -> 0.0
    end

    # Evidence hierarchy weight
    type_weight = case paper_type do
      :review -> 3.0    # Systematic review / meta-analysis
      :trial -> 2.0     # RCT / experiment
      :study -> 1.5     # Observational / single study
      :other -> 1.0     # Unclassified
    end

    # Citation count bonus (log scale)
    citation_bonus = :math.log10(max(citation_count, 2))

    # Final score
    base * type_weight * citation_bonus
  end

  # -- AEC Two-Store: Source Quality Scoring --------------------------------
  # Per arxiv.org/abs/2602.03974 — Active Epistemic Control
  # Only grounded (high-quality) evidence can determine the verdict.
  # Belief (low-quality) evidence provides context but cannot flip direction.

  defp compiled_high_quality_patterns do
    Enum.map(@high_quality_pattern_sources, fn {src, opts} -> Regex.compile!(src, opts) end)
  end

  defp compiled_low_quality_journal_patterns do
    Enum.map(@low_quality_journal_sources, fn {src, opts} -> Regex.compile!(src, opts) end)
  end

  defp score_source_quality(paper) do
    title = (paper["title"] || "") |> String.downcase()
    source = (paper["source"] || "") |> String.downcase()
    abstract = (paper["abstract"] || "") |> String.downcase()
    citations = paper["citation_count"] || paper["citationCount"] || 0
    pub_types = paper["publicationTypes"] || []

    # 1. Citation count score (log scale, normalized to 0-1)
    citation_score = if citations > 0, do: :math.log10(citations) / 5.0, else: 0.0
    citation_score = min(citation_score, 1.0)

    # 2. Publisher/journal quality — low-quality check MUST come first
    # to prevent review-type boost from laundering garbage journals.
    # Only match journal patterns against SOURCE field — matching against title/abstract
    # would nuke every paper when investigating topics like "homeopathy".
    journal_text = "#{source}"
    is_low_quality = Enum.any?(compiled_low_quality_journal_patterns(), &Regex.match?(&1, journal_text))

    # 3. Publication type boost — only if NOT from a low-quality source
    # A "systematic review" in a CAM journal is not the same as one in Cochrane
    is_review_type = not is_low_quality and is_review_or_meta_analysis?(title, pub_types)

    # High-quality patterns match against full text (title + source + abstract)
    all_text = "#{title} #{source} #{abstract}"
    publisher_score = cond do
      is_low_quality -> 0.05  # Low-quality journals always score low, review or not
      is_review_type -> 0.8   # Reviews from non-garbage sources get grounded
      Enum.any?(compiled_high_quality_patterns(), &Regex.match?(&1, all_text)) -> 0.8
      true -> 0.3
    end

    # 4. Combined (citation weight + publisher weight)
    Float.round(citation_score * 0.5 + publisher_score * 0.5, 3)
  end

  # Detect systematic reviews and meta-analyses from publicationTypes field or title keywords
  defp is_review_or_meta_analysis?(title, pub_types) do
    type_match = Enum.any?(List.wrap(pub_types), fn t ->
      t_lower = String.downcase(to_string(t))
      t_lower in ["review", "meta-analysis", "metaanalysis", "systematic review"]
    end)

    title_match = Regex.match?(
      ~r/\b(systematic\s+review|meta[\-\s]?analysis|cochrane|umbrella\s+review)\b/i,
      title
    )

    type_match or title_match
  end

  defp classify_evidence_store(verified_evidence, paper_map) do
    Enum.map(verified_evidence, fn ev ->
      source_quality = case ev.paper_ref do
        nil -> 0.15
        n ->
          case Map.get(paper_map, n) do
            nil -> 0.1
            paper -> score_source_quality(paper)
          end
      end

      store = if source_quality >= @grounded_threshold, do: :grounded, else: :belief
      Map.merge(ev, %{source_quality: source_quality, evidence_store: store})
    end)
  end

  # -- Format papers for LLM context -----------------------------------

  defp format_papers([]), do: "No relevant papers found. Base your arguments on your training knowledge, but mark everything as [REASONING]."
  defp format_papers(papers) do
    papers_text = papers
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} ->
        citations = p["citation_count"] || p["citationCount"] || 0
        source = p["source"] || "unknown"
        abstract = String.slice(to_string(p["abstract"] || ""), 0, 500)
        "[Paper #{i}] #{p["title"]} (#{p["year"]}, #{citations} citations, via #{source})\nAbstract: #{abstract}"
      end)
      |> Enum.join("\n\n")

    "RELEVANT PAPERS FOUND:\n" <> papers_text <>
      "\n\nPapers are sorted by relevance. Citation counts are shown for each paper." <>
      "\nWhen citing, prefer papers with higher citation counts and from established journals." <>
      "\nYou MUST cite specific papers by number [Paper N] when your arguments are based on them."
  end

  # -- Adversarial evidence parsing ------------------------------------

  defp parse_adversarial_evidence(text) do
    ~r/\d+\.\s*\[(SOURCED|REASONING)\]\s*\(strength:\s*(\d+)\)\s*(.+)/i
    |> Regex.scan(text)
    |> Enum.map(fn [_, type, strength_str, summary] ->
      source_type = case String.upcase(type) do
        "SOURCED" -> :sourced
        _ -> :reasoning
      end
      strength = case Integer.parse(strength_str) do
        {n, _} when n >= 1 and n <= 10 -> n
        {n, _} when n > 10 -> 10
        {n, _} when n < 1 -> 1
        _ -> 5
      end
      # Keep LLM-assigned strength for DISPLAY only.
      # Score, verified, paper_type, citation_count filled by verify_citations.
      %{summary: String.trim(summary), source_type: source_type, strength: strength,
        paper_ref: extract_paper_ref(String.trim(summary)),
        verified: false, verification: "pending", paper_type: :other,
        citation_count: 0, score: 0.0}
    end)
  end

  # -- Add evidence to ledger ------------------------------------------

  defp add_evidence_to_ledger(evidence_list, claim, direction) do
    Enum.flat_map(evidence_list, fn ev ->
      # Use hierarchy-weighted VERIFICATION score, not LLM strength
      ledger_strength = ev.score
      case EpistemicLedger.add_evidence(
        [
          claim_id: claim.id,
          summary: ev.summary,
          direction: direction,
          strength: ledger_strength,
          confidence: ledger_strength,
          source_type: Atom.to_string(ev.source_type)
        ],
        @ledger_name
      ) do
        %Models.Evidence{} = record -> [record]
        {:error, reason} ->
          Logger.warning("[investigate] Failed to add evidence: #{inspect(reason)}")
          []
      end
    end)
  end

  # -- Add attacks to ledger (AGAINST arguments = falsification attempts) --

  defp add_attacks_to_ledger(evidence_list, claim) do
    Enum.flat_map(evidence_list, fn ev ->
      # Use hierarchy-weighted VERIFICATION score, not LLM strength
      ledger_severity = ev.score
      source = if ev.source_type == :sourced, do: "paper", else: "llm_reasoning"
      case EpistemicLedger.add_attack(
        [
          claim_id: claim.id,
          description: ev.summary,
          target_kind: "claim",
          target_id: claim.id,
          severity: ledger_severity,
          status: :open,
          metadata: %{
            "source" => source,
            "source_type" => Atom.to_string(ev.source_type),
            "raw_strength" => ev.strength,
            "verified" => ev.verified,
            "verification" => ev.verification,
            "paper_type" => Atom.to_string(ev.paper_type),
            "citation_count" => ev.citation_count,
            "score" => ev.score
          }
        ],
        @ledger_name
      ) do
        %Models.Attack{} = record -> [record]
        {:error, reason} ->
          Logger.warning("[investigate] Failed to add attack: #{inspect(reason)}")
          []
      end
    end)
  end

  # -- Format verified evidence for display -----------------------------

  defp format_verified_evidence([], _heading), do: "(none)"
  defp format_verified_evidence(evidence, heading) do
    lines = evidence
      |> Enum.with_index(1)
      |> Enum.map(fn {ev, i} ->
        type_tag = ev.paper_type |> Atom.to_string() |> String.upcase()
        cite_count = ev.citation_count
        score_str = Float.round(ev.score * 1.0, 1) |> to_string()

        store_label = case Map.get(ev, :evidence_store) do
          :grounded -> "GROUNDED"
          :belief -> "BELIEF"
          _ -> ""
        end

        {status_icon, detail} = case ev.verification do
          "verified" ->
            paper_info = case ev.paper_ref do
              nil -> ""
              n -> "Paper #{n}, "
            end
            cite_str = format_citation_count(cite_count)
            {"VERIFIED \u2713 #{type_tag}", "(#{paper_info}#{cite_str}, score: #{score_str})"}
          "partial" ->
            paper_info = case ev.paper_ref do
              nil -> ""
              n -> "Paper #{n}, "
            end
            cite_str = format_citation_count(cite_count)
            {"PARTIAL ~ #{type_tag}", "(#{paper_info}#{cite_str}, score: #{score_str})"}
          "unverified" ->
            paper_info = case ev.paper_ref do
              nil -> ""
              n -> "Paper #{n}, "
            end
            cite_str = format_citation_count(cite_count)
            {"UNVERIFIED \u2717", "(#{paper_info}#{cite_str}, score: #{score_str}) -- FRAUDULENT CITATION"}
          "no_citation" ->
            {"NO CITATION", "(reasoning only, score: #{score_str})"}
          "invalid_ref" ->
            {"INVALID REF", "(score: 0.0 -- cited paper doesn't exist)"}
          _ ->
            {"PENDING", "(score: #{score_str})"}
        end

        store_tag = if store_label != "", do: " [#{store_label}]", else: ""
        "  #{i}. [#{status_icon}]#{store_tag} #{detail} #{ev.summary}"
      end)
      |> Enum.join("\n")

    "#{heading}\n#{lines}"
  end

  defp format_citation_count(count) when count >= 1000 do
    "#{Float.round(count / 1000.0, 1)}k citations"
  end
  defp format_citation_count(count), do: "#{count} citations"

  # -- Code execution callback (Crucible or local fallback) ----------------

  defp build_code_fn do
    crucible_url = System.get_env("VAOS_CRUCIBLE_GRPC_URL")

    if crucible_url do
      # Production: use vas-crucible sandbox via HTTP proxy
      fn code, opts ->
        language = Keyword.get(opts, :language, "python")
        kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"

        # Get JWT for sandbox auth
        agent_id = "osa"
        intent_hash = :crypto.hash(:sha256, code) |> Base.encode16(case: :lower) |> binary_part(0, 16)

        # GrpcClient may not be available in all OSA installations.
        # Fall back to HTTP token request if the module isn't loaded.
        jwt = cond do
          Code.ensure_loaded?(OptimalSystemAgent.VasSwarm.GrpcClient) ->
            case apply(OptimalSystemAgent.VasSwarm.GrpcClient, :request_token, [agent_id, intent_hash, "execute"]) do
              {:ok, token} -> token
              _ -> nil
            end
          true ->
            # Direct HTTP fallback to vaos-kernel
            case Req.post("#{kernel_http}/api/v1/token",
                   json: %{agent_id: agent_id, intent_hash: intent_hash, scope: "execute"},
                   receive_timeout: 5_000) do
              {:ok, %{status: 200, body: %{"token" => token}}} -> token
              {:ok, %{status: 200, body: %{"jwt" => token}}} -> token
              _ -> nil
            end
        end

        if jwt do
          body = Jason.encode!(%{code: code, language: language, jwt: jwt})
          case Req.post("#{crucible_url}/execute",
                 body: body,
                 headers: [{"content-type", "application/json"}],
                 receive_timeout: 30_000) do
            {:ok, %{status: 200, body: resp}} ->
              {:ok, %{stdout: resp["stdout"] || "", stderr: resp["stderr"] || ""}}
            {:ok, %{status: status, body: body}} ->
              {:error, "Crucible returned #{status}: #{inspect(body)}"}
            {:error, reason} ->
              {:error, "Crucible unreachable: #{inspect(reason)}"}
          end
        else
          {:error, "No JWT available for sandbox auth"}
        end
      end
    else
      # Local fallback: run Python in a restricted tmpdir (dev mode only)
      fn code, opts ->
        language = Keyword.get(opts, :language, "python")
        if language != "python" do
          {:error, "Local fallback only supports Python"}
        else
          work_dir = System.tmp_dir!() |> Path.join("crucible_#{:rand.uniform(999999)}")
          File.mkdir_p!(work_dir)
          script_path = Path.join(work_dir, "script.py")
          File.write!(script_path, code)

          try do
            {output, exit_code} = System.cmd("python3", [script_path],
              cd: work_dir,
              stderr_to_stdout: true,
              env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
            )
            if exit_code == 0 do
              {:ok, %{stdout: output, stderr: ""}}
            else
              {:ok, %{stdout: "", stderr: output}}
            end
          rescue
            e -> {:error, "Local exec failed: #{Exception.message(e)}"}
          after
            File.rm_rf!(work_dir)
          end
        end
      end
    end
  end

  # -- Format paper list for display -----------------------------------

  defp format_paper_list(all_papers) do
    all_papers
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} ->
      citations = p["citation_count"] || p["citationCount"] || 0
      source = p["source"] || "unknown"
      doi_suffix = case p["doi"] do
        doi when is_binary(doi) and doi != "" -> " | https://doi.org/#{doi}"
        _ -> ""
      end
      "  [Paper #{i}] #{p["title"]} (#{p["year"]}, #{citations} citations, via #{source})#{doi_suffix}"
    end)
    |> Enum.join("\n")
  end

  # -- Helpful counter increment (compound loop) -----------------------

  defp increment_helpful_for_reused_evidence(store, prior_evidence_texts, current_evidence) do
    # Only increment helpful counter when prior evidence is independently regenerated
    Enum.each(prior_evidence_texts, fn prior_text ->
      # Check if any current evidence covers the same ground
      was_reused = Enum.any?(current_evidence, fn ev ->
        prior_words = significant_words(prior_text)
        ev_words = significant_words(ev.summary)
        set1 = MapSet.new(prior_words)
        set2 = MapSet.new(ev_words)
        intersection = MapSet.intersection(set1, set2) |> MapSet.size()
        union_size = MapSet.union(set1, set2) |> MapSet.size()
        union_size > 0 and (intersection * 1.0 / union_size) >= 0.3
      end)

      if was_reused do
        case Regex.run(~r/\(id:\s*(investigate:[a-f0-9]+)\)/, prior_text) do
          [_, prior_id] ->
            query = "SELECT ?ev ?count WHERE { <#{prior_id}> vaos:has_evidence ?ev . ?ev vaos:helpful_count ?count }"
            case MiosaKnowledge.sparql(store, query) do
              {:ok, results} when is_list(results) ->
                for r <- results do
                  ev_id = Map.get(r, "ev", "")
                  old_count_str = Map.get(r, "count", "0")
                  old_count = case Integer.parse(old_count_str) do
                    {n, _} -> n
                    :error -> 0
                  end
                  MiosaKnowledge.retract(store, {ev_id, "vaos:helpful_count", old_count_str})
                  MiosaKnowledge.assert(store, {ev_id, "vaos:helpful_count", Integer.to_string(old_count + 1)})
                  Logger.debug("[investigate] Incremented helpful count for #{ev_id} to #{old_count + 1}")
                end
              _ -> :ok
            end
          _ -> :ok
        end
      end
    end)
  end

  defp significant_words(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.take(10)
  end



  # -- Keyword extraction ----------------------------------------------

  defp extract_keywords(topic) do
    topic
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.flat_map(fn word ->
      stem = word
        |> String.replace(~r/ing$/, "")
        |> String.replace(~r/tion$/, "t")
        |> String.replace(~r/ness$/, "")
        |> String.replace(~r/ment$/, "")
        |> String.replace(~r/able$/, "")
        |> String.replace(~r/ible$/, "")
        |> String.replace(~r/ly$/, "")
        |> String.replace(~r/ed$/, "")
        |> String.replace(~r/er$/, "")
        |> String.replace(~r/es$/, "")
        |> String.replace(~r/s$/, "")
      if stem != word and String.length(stem) >= 3, do: [word, stem], else: [word]
    end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  # -- Prior knowledge search — fetches EVIDENCE, not conclusions ------

  defp fetch_prior_evidence_by_keywords(store, keywords) do
    # Find prior investigations that match keywords
    topic_query = "SELECT ?s ?topic WHERE { ?s vaos:topic ?topic . ?s rdf:type vaos:Investigation }"
    kw_query = "SELECT ?s ?kw WHERE { ?s vaos:keyword ?kw . ?s rdf:type vaos:Investigation }"

    topic_results = case MiosaKnowledge.sparql(store, topic_query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end

    kw_results = case MiosaKnowledge.sparql(store, kw_query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end

    kw_matched_ids =
      kw_results
      |> Enum.filter(fn bindings ->
        stored_kw = Map.get(bindings, "kw", "") |> to_string() |> String.downcase()
        Enum.any?(keywords, fn kw -> kw == stored_kw or String.contains?(stored_kw, kw) or String.contains?(kw, stored_kw) end)
      end)
      |> Enum.map(fn bindings -> Map.get(bindings, "s", "") |> to_string() end)
      |> MapSet.new()

    matched_ids = topic_results
      |> Enum.filter(fn bindings ->
        s = Map.get(bindings, "s", "") |> to_string()
        topic_val = Map.get(bindings, "topic", Map.get(bindings, :topic, ""))
        topic_lower = String.downcase(to_string(topic_val))
        topic_match = Enum.any?(keywords, fn kw -> String.contains?(topic_lower, kw) end)
        kw_match = MapSet.member?(kw_matched_ids, s)
        topic_match or kw_match
      end)
      |> Enum.map(fn bindings -> Map.get(bindings, "s", "") |> to_string() end)

    # For each matched investigation, fetch the EVIDENCE summaries (not conclusions)
    Enum.flat_map(matched_ids, fn inv_id ->
      ev_query = "SELECT ?ev ?summary WHERE { <#{inv_id}> vaos:has_evidence ?ev . ?ev vaos:summary ?summary }"
      case MiosaKnowledge.sparql(store, ev_query) do
        {:ok, results} when is_list(results) ->
          Enum.map(results, fn r ->
            summary = Map.get(r, "summary", "")
            "  - #{summary} (id: #{inv_id})"
          end)
        _ -> []
      end
    end)
    |> Enum.take(10)  # Limit keyword-matched to 10
    |> then(fn keyword_results ->
      # Widen: also search ALL evidence summaries for term overlap with topic
      broad_results = fetch_broad_evidence(store, keywords)
      # Merge, deduplicate by summary text
      seen = MapSet.new(Enum.map(keyword_results, fn line -> String.trim(line) end))
      additional = Enum.reject(broad_results, fn line -> MapSet.member?(seen, String.trim(line)) end)
      (keyword_results ++ Enum.take(additional, 10))
    end)
  rescue
    e ->
      Logger.warning("[investigate] fetch_prior_evidence_by_keywords failed: #{Exception.message(e)}")
      []
  end

  defp fetch_broad_evidence(store, keywords) do
    # Search ALL evidence summaries across ALL investigations for term overlap
    all_ev_query = "SELECT ?ev ?summary WHERE { ?ev vaos:summary ?summary }"
    case MiosaKnowledge.sparql(store, all_ev_query) do
      {:ok, results} when is_list(results) ->
        kw_set = MapSet.new(keywords)
        results
        |> Enum.filter(fn r ->
          summary = Map.get(r, "summary", "") |> to_string() |> String.downcase()
          summary_words = String.split(summary, ~r/\s+/, trim: true) |> MapSet.new()
          overlap = MapSet.intersection(kw_set, summary_words) |> MapSet.size()
          overlap >= 2  # At least 2 keyword matches
        end)
        |> Enum.map(fn r ->
          summary = Map.get(r, "summary", "")
          ev_id = Map.get(r, "ev", "")
          "  - #{summary} (id: #{ev_id})"
        end)
      _ -> []
    end
  rescue
    _ -> []
  end

  # -- Multi-source literature search: Semantic Scholar + OpenAlex + alphaXiv --

  defp search_all_papers(topic, keywords \\ []) do
    http_fn = literature_http_fn()
    {ss_queries, oa_queries} = build_search_queries(topic, keywords)

    # SS: sequential with 1.5s delay — unauthenticated rate limit is ~1 req/s.
    # Concurrent requests all hit 429 simultaneously and waste all retries.
    ss_results = Enum.flat_map(Enum.with_index(ss_queries), fn {{label, query, opts}, idx} ->
      if idx > 0, do: Process.sleep(1_500)
      search_opts = Keyword.merge([limit: 5], opts)
      case Literature.search_semantic_scholar(query, http_fn, search_opts) do
        {:ok, papers} -> [{:"ss_#{label}", papers}]
        _ -> [{:"ss_#{label}", []}]
      end
    end)
    ss_tasks = []  # No async tasks for SS

    # OA is more generous with rate limits — send all queries
    oa_tasks = Enum.map(oa_queries, fn {label, query, opts} ->
      search_opts = Keyword.merge([limit: 5], opts)
      Task.async(fn ->
        case Literature.search_openalex(query, http_fn, search_opts) do
          {:ok, papers} -> {:"oa_#{label}", papers}
          _ -> {:"oa_#{label}", []}
        end
      end)
    end)

    # alphaXiv embedding search (always included, covers both sides)
    alphaxiv_task = Task.async(fn ->
      alias OptimalSystemAgent.Tools.Builtins.AlphaXivClient
      case AlphaXivClient.embedding_search(topic) do
        {:ok, papers} when papers != [] ->
          Logger.debug("[investigate] alphaXiv returned #{length(papers)} papers")
          {:alphaxiv, papers}
        _ ->
          Logger.debug("[investigate] alphaXiv unavailable")
          {:alphaxiv, []}
      end
    end)

    async_results = Task.await_many(oa_tasks ++ [alphaxiv_task], 30_000)
    results = ss_results ++ async_results

    # Collect source counts
    source_counts = Enum.reduce(results, %{}, fn {source, papers}, acc ->
      source_key = source |> Atom.to_string() |> source_category()
      Map.update(acc, source_key, length(papers), &(&1 + length(papers)))
    end)

    # Collect raw papers and ensure atom keys for rank_papers compatibility
    all_raw = Enum.flat_map(results, fn {_source, papers} ->
      Enum.map(papers, &ensure_atom_keys/1)
    end)

    # Dedup by title similarity (works on both atom and string keys)
    deduped = merge_papers_raw(all_raw)

    # Rank by relevance BEFORE normalizing (papers have atom keys)
    ranked = Literature.rank_papers(deduped, topic)

    # Filter out irrelevant papers (zero topic-term overlap)
    {relevant, dropped} = filter_relevant(ranked, topic, keywords)
    if dropped > 0 do
      Logger.info("[investigate] Filtered out #{dropped} irrelevant papers")
    end

    # Normalize to string-key format and take top 15
    sorted = relevant
    |> Enum.map(&normalize_paper_format/1)
    |> Enum.take(15)

    {sorted, source_counts}
  end

  # Build search queries split by API. SS gets 3 queries (rate limit safe),
  # OA gets all 7+ (generous rate limits). Returns {ss_queries, oa_queries}.
  defp build_search_queries(topic, keywords) do
    topic_words = topic |> String.downcase() |> String.split(~r/\s+/, trim: true) |> MapSet.new()
    novel_keywords = Enum.reject(keywords, fn kw -> MapSet.member?(topic_words, kw) end) |> Enum.take(3)

    # Opts for review-specific queries: filter at API level for reviews/meta-analyses
    review_opts = [publication_types: "Review,MetaAnalysis", type: "review"]

    # SS: only 3 highest-value queries (avoids rate limiting without API key)
    ss_queries = [
      {:topic, topic, []},
      {:reviews, "systematic review #{topic}", review_opts},
      {:rct, "randomized controlled trial #{topic}", []}
    ]

    # OA: all queries (10 req/s polite pool)
    oa_queries = [
      {:topic, topic, []},
      {:reviews, "systematic review #{topic}", review_opts},
      {:cochrane, "Cochrane review #{topic}", review_opts},
      {:placebo, "#{topic} placebo controlled trial", []},
      {:consensus, "scientific consensus #{topic}", []},
      {:critique, "#{topic} critical evaluation", []},
      {:rct, "randomized controlled trial #{topic}", []}
    ]

    # Add keyword-augmented query to OA only if novel keywords exist
    oa_queries = if novel_keywords != [] do
      oa_queries ++ [{:keywords, "#{topic} #{Enum.join(novel_keywords, " ")}", []}]
    else
      oa_queries
    end

    {ss_queries, oa_queries}
  end

  # Categorize source labels into summary keys
  defp source_category("alphaxiv"), do: :alphaxiv
  defp source_category("ss_" <> _), do: :semantic_scholar
  defp source_category("oa_" <> _), do: :openalex
  defp source_category(_other), do: :other

  # Dedup raw papers (handles both atom-key and string-key formats)
  defp merge_papers_raw(papers) when is_list(papers) do
    Enum.uniq_by(papers, fn p ->
      title = case p do
        %{title: t} -> t
        %{"title" => t} -> t
        _ -> ""
      end

      title
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.split()
      |> Enum.reject(&(String.length(&1) < 4))
      |> Enum.sort()
      |> Enum.take(5)
      |> Enum.join(" ")
    end)
  end

  # Filter papers by topic-term overlap. Returns {relevant_papers, dropped_count}.
  # Requires the MOST SPECIFIC term (longest word) to appear in title or abstract.
  # This prevents generic words like "effectiveness" from matching unrelated papers
  # (e.g. "Effectiveness of treatments for firework fears in dogs").
  defp filter_relevant(papers, topic, _keywords) do
    # Extract distinctive terms from topic — skip short/generic words
    distinctive_terms = topic
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 4))

    # Generic modifiers that appear across many domains — never use as primary filter term
    generic_modifiers = ~w(effectiveness effective efficacy efficient analysis review evidence impact treatment treatments outcomes study studies comparison)

    # Primary term: first non-generic term, or longest term as fallback
    primary_term = Enum.find(distinctive_terms, fn t -> t not in generic_modifiers end) ||
      Enum.max_by(distinctive_terms, &String.length/1, fn -> nil end)

    # If no distinctive terms found, skip filtering entirely
    if primary_term == nil do
      {papers, 0}
    else
      {relevant, dropped} = Enum.split_with(papers, fn paper ->
        {title, abstract} = case paper do
          %{title: t, abstract: a} -> {t, a}
          %{"title" => t, "abstract" => a} -> {t, a}
          _ -> {"", ""}
        end

        paper_text = "#{title} #{abstract}"
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9\s\-]/, " ")

        # Primary (most specific) term MUST appear in title or abstract
        String.contains?(paper_text, primary_term)
      end)

      {relevant, length(dropped)}
    end
  end

  # Normalize Literature module structs (atom keys) to the string-key format
  # used throughout investigate.ex
  defp normalize_paper_format(%{title: t, source: src} = paper) do
    %{
      "title" => to_string(t || "Unknown"),
      "abstract" => to_string(paper[:abstract] || ""),
      "year" => to_string(paper[:year] || "unknown"),
      "citation_count" => paper[:citation_count] || 0,
      "citationCount" => paper[:citation_count] || 0,
      "source" => to_string(src),
      "authors" => Enum.join(paper[:authors] || [], ", "),
      "paper_id" => to_string(paper[:paper_id] || ""),
      "url" => to_string(paper[:url] || ""),
      "doi" => to_string(paper[:doi] || ""),
      "publicationTypes" => paper[:publication_types] || []
    }
  end

  # Already string-keyed (from alphaXiv or legacy formats)
  defp normalize_paper_format(%{"title" => _} = paper) do
    Map.merge(%{
      "citation_count" => 0,
      "citationCount" => 0,
      "source" => "alphaxiv",
      "authors" => "",
      "abstract" => "",
      "year" => "unknown",
      "publicationTypes" => []
    }, paper)
    |> Map.update("citation_count", 0, fn v -> v || 0 end)
    |> Map.update("citationCount", 0, fn v -> v || 0 end)
  end

  defp normalize_paper_format(other) do
    Logger.warning("[investigate] Unknown paper format: #{inspect(other) |> String.slice(0, 200)}")
    %{"title" => "Unknown", "abstract" => "", "year" => "unknown",
      "citation_count" => 0, "citationCount" => 0, "source" => "unknown"}
  end

  # Convert string-keyed papers (e.g. from alphaXiv) to atom keys for rank_papers compatibility
  defp ensure_atom_keys(%{title: _} = paper), do: paper
  defp ensure_atom_keys(%{"title" => _} = paper) do
    %{
      title: paper["title"] || "",
      abstract: paper["abstract"] || "",
      year: parse_year(paper["year"]),
      citation_count: paper["citation_count"] || paper["citationCount"] || 0,
      source: safe_to_atom(paper["source"] || "alphaxiv"),
      authors: paper["authors"] || [],
      paper_id: paper["paper_id"] || paper["paperId"] || "",
      url: paper["url"] || "",
      doi: paper["doi"] || nil,
      publication_types: paper["publicationTypes"] || []
    }
  end
  defp ensure_atom_keys(other), do: other

  # Safe atom conversion for known source values
  defp safe_to_atom(s) when is_atom(s), do: s
  defp safe_to_atom("semantic_scholar"), do: :semantic_scholar
  defp safe_to_atom("openalex"), do: :openalex
  defp safe_to_atom("alphaxiv"), do: :alphaxiv
  defp safe_to_atom(_), do: :unknown

  defp parse_year(nil), do: nil
  defp parse_year(y) when is_integer(y), do: y
  defp parse_year(y) when is_binary(y) do
    case Integer.parse(y) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_year(_), do: nil

  # HTTP adapter for vaos-ledger Literature module — uses Req
  defp literature_http_fn do
    fn url, opts ->
      params = Keyword.get(opts, :params, [])
      headers = Keyword.get(opts, :headers, [])

      # Build query string from params
      query_string = case params do
        [] -> ""
        kv_list ->
          kv_list
          |> Enum.map(fn
            {k, v} -> "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}"
            other -> to_string(other)
          end)
          |> Enum.join("&")
      end

      full_url = if query_string == "", do: url, else: "#{url}?#{query_string}"
      req_headers = Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

      case Req.get(full_url, headers: req_headers, receive_timeout: 15_000) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, body}

        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded}
            err -> {:error, {:json_decode_failed, err}}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.warning("[investigate] HTTP #{status} from #{url}: #{inspect(body) |> String.slice(0, 200)}")
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          Logger.warning("[investigate] HTTP request failed for #{url}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp format_source_counts(counts) do
    counts
    |> Enum.map(fn {source, count} -> "#{count} via #{source}" end)
    |> Enum.join(", ")
  end

  # -- Cross-investigation contradiction detection ---------------------

  defp detect_contradictions(store, current_id, current_direction, current_keywords) do
    case MiosaKnowledge.sparql(store, "SELECT ?s ?topic WHERE { ?s vaos:topic ?topic . ?s rdf:type vaos:Investigation }") do
      {:ok, results} when is_list(results) ->
        results
        |> Enum.reject(fn r -> Map.get(r, "s") == current_id end)
        |> Enum.filter(fn r ->
          prior_topic = Map.get(r, "topic", "") |> String.downcase()
          Enum.any?(current_keywords, fn kw -> String.contains?(prior_topic, kw) end)
        end)
        |> Enum.flat_map(fn r ->
          prior_id = Map.get(r, "s", "")
          prior_topic = Map.get(r, "topic", "")

          case MiosaKnowledge.sparql(store, "SELECT ?dir WHERE { <#{prior_id}> vaos:direction ?dir }") do
            {:ok, [prior | _]} ->
              prior_direction = Map.get(prior, "dir", "unknown")

              is_conflict =
                (current_direction == "supporting" and prior_direction in ["opposing", "genuinely_contested"]) or
                (current_direction == "opposing" and prior_direction in ["supporting", "genuinely_contested"]) or
                (current_direction != prior_direction and current_direction != "genuinely_contested" and prior_direction != "genuinely_contested")

              if is_conflict do
                MiosaKnowledge.assert(store, {current_id, "vaos:contradicts", prior_id})
                MiosaKnowledge.assert(store, {prior_id, "vaos:contradictedBy", current_id})
                Logger.warning("[investigate] Epistemic tension: #{current_id} contradicts #{prior_id}")
                [%{prior_id: prior_id, prior_topic: prior_topic, prior_direction: prior_direction}]
              else
                []
              end
            _ -> []
          end
        end)
      _ -> []
    end
  end

  # -- Cached citation verification (uses Scorer ETS table) -----------

  defp cached_verify(evidence, paper) do
    # Use the same ETS table as Vaos.Ledger.Experiment.Scorer for caching
    ensure_scorer_cache()
    cache_key = :erlang.phash2({evidence.summary, paper["title"]})

    case :ets.lookup(:scorer_cache, {:verify, cache_key}) do
      [{{:verify, ^cache_key}, result}] ->
        Logger.debug("[investigate] Cache hit for citation verification")
        result

      [] ->
        result = verify_single_citation(evidence, paper)
        :ets.insert(:scorer_cache, {{:verify, cache_key}, result})
        result
    end
  end

  defp ensure_scorer_cache do
    if :ets.whereis(:scorer_cache) == :undefined do
      try do
        :ets.new(:scorer_cache, [:set, :public, :named_table])
      rescue
        ArgumentError -> :ok  # Another process created it between whereis and new
      end
    end

    :ok
  end

  # -- Advocacy quality assessment (Referee-inspired) -----------------

  defp assess_advocacy_quality(supporting, opposing) do
    for_fraud_rate =
      if supporting == [] do
        0.0
      else
        Enum.count(supporting, fn ev -> ev.verification == "unverified" end) / length(supporting)
      end

    against_fraud_rate =
      if opposing == [] do
        0.0
      else
        Enum.count(opposing, fn ev -> ev.verification == "unverified" end) / length(opposing)
      end

    cond do
      for_fraud_rate > 0.5 ->
        "### Advocacy Quality Warning\n" <>
          "FOR advocate had #{round(for_fraud_rate * 100)}% fraudulent citations -- arguments are poorly grounded"

      against_fraud_rate > 0.5 ->
        "### Advocacy Quality Warning\n" <>
          "AGAINST advocate had #{round(against_fraud_rate * 100)}% fraudulent citations -- arguments are poorly grounded"

      for_fraud_rate > 0.3 or against_fraud_rate > 0.3 ->
        "### Advocacy Quality Note\n" <>
          "Some citations were not supported by paper abstracts -- interpret with caution " <>
          "(FOR: #{round(for_fraud_rate * 100)}% unverified, AGAINST: #{round(against_fraud_rate * 100)}% unverified)"

      true ->
        ""
    end
  end

  # -- Uncertainty iteration hint (Experiment.Loop-inspired) ----------

  defp maybe_suggest_iteration(claim, ledger_name) do
    try do
      metrics = EpistemicLedger.claim_metrics(claim.id, ledger_name)
      uncertainty = metrics["uncertainty"]

      if uncertainty > 0.5 do
        "\n### Iteration Suggested\n" <>
          "High uncertainty detected (#{Float.round(uncertainty * 1.0, 3)}). " <>
          "Consider re-investigating with more specific sub-questions to reduce epistemic uncertainty.\n"
      else
        ""
      end
    rescue
      _ -> ""
    end
  end

  # -- Deep research mode (Pipeline integration) ----------------------
  #
  # Runner (Vaos.Ledger.ML.Runner) is available for code-execution
  # investigations in a future "experimental" depth mode.
  # When depth: "experimental":
  #   alias Vaos.Ledger.ML.Runner
  #   Runner.start_link(trial_id: topic_id, experiment_fn: fn config -> ... end,
  #                     max_steps: 100, max_seconds: 120)
  #   This would execute Python/Elixir code to test hypotheses empirically,
  #   with Referee (Vaos.Ledger.ML.Referee) monitoring trials and killing
  #   underperformers via early stopping.

  defp deep_research_note(topic, claim, _all_papers, _store) do
    try do
      Logger.info("[investigate] Running deep research pipeline for: #{topic}")

      # Build an LLM callback compatible with Pipeline
      llm_fn = fn prompt ->
        model = Application.get_env(:optimal_system_agent, :utility_model)
        llm_opts = [temperature: 0.3, max_tokens: 8192]
        llm_opts = if model, do: Keyword.put(llm_opts, :model, model), else: llm_opts
        messages = [%{role: "user", content: prompt}]

        case Providers.chat(messages, llm_opts) do
          {:ok, %{content: response}} when is_binary(response) -> {:ok, response}
          {:ok, other} -> {:error, {:unexpected_response, other}}
          {:error, reason} -> {:error, reason}
        end
      end

      # Build an HTTP callback for literature search
      http_fn = literature_http_fn()

      # Generate hypotheses from the investigation topic
      hypotheses = generate_research_hypotheses(topic, claim, llm_fn)

      if hypotheses == [] do
        ""
      else
        # Run lightweight pipeline passes for each hypothesis (idea -> method -> literature)
        # Code execution via Crucible sandbox (or local fallback in dev)
        results =
          hypotheses
          |> Enum.take(3)
          |> Enum.map(fn hypothesis ->
            try do
              case Pipeline.run(
                     ledger: ensure_ledger_pid(),
                     llm_fn: llm_fn,
                     code_fn: build_code_fn(),
                     input: hypothesis,
                     http_fn: http_fn,
                     max_iterations: 1,
                     target_score: 0.5
                   ) do
                {:ok, pipeline_state} ->
                  research = pipeline_state.research
                  summary = String.slice(research.idea || "", 0, 200)
                  method_summary = String.slice(research.methodology || "", 0, 200)

                  # Determine direction from hypothesis/summary content
                  research_direction = cond do
                    Regex.match?(~r/\b(refut|contra|disprove|against|fail|negat|not\s+support)\b/i, hypothesis <> " " <> summary) ->
                      :oppose
                    true ->
                      :support
                  end

                  # Add finding as new evidence to the ledger
                  EpistemicLedger.add_evidence(
                    [
                      claim_id: claim.id,
                      summary: "Deep research finding: #{summary}",
                      direction: research_direction,
                      strength: 0.3,
                      confidence: 0.3,
                      source_type: "research_pipeline",
                      metadata: %{"hypothesis" => hypothesis, "method" => method_summary}
                    ],
                    @ledger_name
                  )

                  {:ok, %{hypothesis: hypothesis, idea: summary, method: method_summary}}

                {:error, reason} ->
                  {:error, %{hypothesis: hypothesis, reason: inspect(reason)}}
              end
            rescue
              e -> {:error, %{hypothesis: hypothesis, reason: Exception.message(e)}}
            end
          end)

        # Refresh claim metrics after adding new evidence
        EpistemicLedger.refresh_claim(claim.id, @ledger_name)
        EpistemicLedger.save(@ledger_name)

        # Format results
        ok_results = Enum.filter(results, fn {status, _} -> status == :ok end)
        err_results = Enum.filter(results, fn {status, _} -> status == :error end)

        if ok_results == [] do
          "\n### Deep Research\nPipeline attempted #{length(hypotheses)} hypotheses but all failed.\n"
        else
          lines =
            ok_results
            |> Enum.with_index(1)
            |> Enum.map(fn {{:ok, r}, i} ->
              "  #{i}. **Hypothesis:** #{r.hypothesis}\n" <>
                "     **Idea:** #{r.idea}\n" <>
                "     **Method:** #{r.method}"
            end)
            |> Enum.join("\n\n")

          err_note =
            if err_results != [] do
              "\n  (#{length(err_results)} hypothesis pipeline(s) failed)"
            else
              ""
            end

          "\n### Deep Research (Pipeline)\n" <>
            "Generated #{length(hypotheses)} hypotheses, ran #{length(ok_results)} successfully:\n\n" <>
            lines <> err_note <> "\n"
        end
      end
    rescue
      e ->
        Logger.warning("[investigate] Deep research failed: #{Exception.message(e)}")
        "\n### Deep Research\nPipeline failed: #{Exception.message(e)}\n"
    end
  end

  defp generate_research_hypotheses(topic, _claim, llm_fn) do
    prompt = """
    Given this research topic, generate 3 testable hypotheses that could advance
    understanding. Each hypothesis should be specific, falsifiable, and distinct.

    Topic: #{topic}

    Respond with one hypothesis per line, numbered 1-3. Just the hypothesis text, nothing else.
    """

    case llm_fn.(prompt) do
      {:ok, response} ->
        response
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          line
          |> String.replace(~r/^\d+\.\s*/, "")
          |> String.trim()
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(3)

      {:error, _} ->
        []
    end
  end

  defp ensure_ledger_pid do
    case Process.whereis(@ledger_name) do
      nil ->
        {:ok, pid} = EpistemicLedger.start_link(path: @ledger_path, name: @ledger_name)
        pid

      pid ->
        pid
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp short_hash(topic) do
    Base.encode16(:crypto.hash(:sha256, topic), case: :lower) |> String.slice(0, 16)
  end

  defp ensure_ledger_started do
    case Process.whereis(@ledger_name) do
      nil ->
        case EpistemicLedger.start_link(path: @ledger_path, name: @ledger_name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok  # Another process started it between whereis and start_link
        end
      _pid ->
        :ok
    end
  end

  defp store_ref, do: "osa_default"

  defp ensure_store_started do
    case Vaos.Knowledge.open("osa_default") do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} ->
        Logger.error("[investigate] Failed to start knowledge store: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
