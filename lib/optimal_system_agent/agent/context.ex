defmodule OptimalSystemAgent.Agent.Context do
  @moduledoc """
  Two-tier token-budgeted system prompt assembly.

  ## Architecture

  The context builder operates in two tiers:

      Tier 1 — Static Base (cached, from Soul.static_base/0)
        SYSTEM.md interpolated with {{TOOL_DEFINITIONS}}, {{RULES}}, {{USER_PROFILE}}.
        Cached in persistent_term. Never recomputed within a session.
        Includes Signal Theory instructions — the LLM self-classifies signals.

      Tier 2 — Dynamic Context (per-request, token-budgeted)
        Runtime, environment, plan mode, memory, tasks, workflow.
        All blocks are budget-fitted to prevent overflow.

  No code-level signal classification on the hot path. The LLM reads the
  Signal Theory tables in SYSTEM.md and applies Mode/Genre/Weight behavior
  natively — same pattern as the upstream agent CLI, Cursor, Windsurf.

  ## Token Budget

      dynamic_budget = max_tokens - static_tokens - conversation_tokens - reserve

  ## Provider Cache Hints

  For Anthropic, the system message is split into 2 content blocks:
    - Static base with `cache_control: %{type: "ephemeral"}` (~90% cache hit)
    - Dynamic context (per-request, uncached)

  ## Public API

      build(state)         — returns %{messages: [system_msg | conversation]}
      token_budget(state)  — returns token usage breakdown map
  """

  require Logger

  alias OptimalSystemAgent.Agent.Context.Budget
  alias OptimalSystemAgent.Agent.ProjectInstructions
  alias OptimalSystemAgent.Agent.Scratchpad
  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Agent.Memory.Episodic
  alias OptimalSystemAgent.Memory.Scoring
  alias OptimalSystemAgent.Soul

  @response_reserve 8_192

  defp max_tokens, do: Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Builds the full message list (system prompt + conversation history) within
  the configured token budget.

  Returns `%{messages: [system_msg | conversation_messages]}`.
  """
  @spec build(map()) :: %{messages: [map()]}
  def build(state, _signal), do: build(state)

  def build(state) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    provider =
      Map.get(state, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    # Single source of truth for the window OSA actually operates within. For
    # local providers this is capped to :ollama_num_ctx (the same num_ctx we send
    # to Ollama), so the assembled prompt is budgeted against the REAL window
    # rather than the model's trained maximum. nil/"" model resolves to the config
    # default, preserving prior cloud behavior.
    max_tok =
      OptimalSystemAgent.Providers.Registry.effective_context_window(
        Map.get(state, :model),
        provider
      )

    # Local providers (or any small effective window) get the LITE static base:
    # only the core-tool allowlist is inlined; every other tool is advertised by
    # name in a <system-reminder> and pulled on demand via tool_search. This keeps
    # the static base ~4-6k instead of ~24k so the assembled prompt fits a real
    # <=32k window (and so num_ctx isn't forced up to 32k+).
    lite? = provider in [:ollama, :lmstudio, :llamacpp] or max_tok < 40_000

    # Subagents with a system_prompt_override use that instead of Soul.static_base.
    # This gives each agent role its own focused prompt from AGENT.md.
    static_base =
      case Map.get(state, :system_prompt_override) do
        override when override in [nil, ""] ->
          if lite?, do: Soul.static_base(:lite), else: Soul.static_base()

        override ->
          override
      end

    static_tokens =
      case Map.get(state, :system_prompt_override) do
        override when override in [nil, ""] ->
          if lite?, do: Soul.static_token_count(:lite), else: Soul.static_token_count()

        override ->
          estimate_tokens(override)
      end

    # Tier 2: Dynamic context. Essentials fit into the leftover slack; the
    # RECALL group (memory/project/skills) is additionally capped to a fraction
    # of the REAL window so trivial turns can't balloon into the free space.
    dynamic_budget = max(max_tok - @response_reserve - conversation_tokens - static_tokens, 1_000)
    dynamic_context = assemble_dynamic_context(state, dynamic_budget, max_tok)

    dynamic_tokens = estimate_tokens(dynamic_context)
    total_tokens = static_tokens + dynamic_tokens + conversation_tokens + @response_reserve

    Logger.debug(
      "Context.build: static=#{static_tokens} dynamic=#{dynamic_tokens} " <>
        "conversation=#{conversation_tokens} reserve=#{@response_reserve} " <>
        "total=#{total_tokens}/#{max_tok} (#{Float.round(total_tokens / max_tok * 100, 1)}%)"
    )

    system_msg = build_system_message(static_base, dynamic_context, provider)
    %{messages: [system_msg | conversation]}
  end

  @doc """
  Returns a token usage breakdown for debugging purposes.
  """
  @spec token_budget(map()) :: map()
  def token_budget(state) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    max_tok = max_tokens()
    static_tokens = Soul.static_token_count()

    # Gather dynamic blocks for individual cost breakdown
    blocks = gather_dynamic_blocks(state)

    block_details =
      Enum.map(blocks, fn {content, priority, label} ->
        %{
          label: label,
          priority: priority,
          tokens: estimate_tokens(content || "")
        }
      end)

    dynamic_budget = max(max_tok - @response_reserve - conversation_tokens - static_tokens, 1_000)
    dynamic_context = assemble_dynamic_context(state, dynamic_budget, max_tok)
    dynamic_tokens = estimate_tokens(dynamic_context)
    total_tokens = static_tokens + dynamic_tokens + conversation_tokens + @response_reserve

    %{
      max_tokens: max_tok,
      response_reserve: @response_reserve,
      conversation_tokens: conversation_tokens,
      static_base_tokens: static_tokens,
      dynamic_context_tokens: dynamic_tokens,
      system_prompt_budget: max_tok - @response_reserve - conversation_tokens,
      system_prompt_actual: static_tokens + dynamic_tokens,
      total_tokens: total_tokens,
      utilization_pct: Float.round(total_tokens / max_tok * 100, 1),
      headroom: max_tok - total_tokens,
      blocks: block_details
    }
  end

  # ---------------------------------------------------------------------------
  # System message construction
  # ---------------------------------------------------------------------------

  defp build_system_message(static_base, dynamic_context, provider) do
    if provider == :anthropic and dynamic_context != "" do
      # Anthropic cache hint: split into 2 content blocks.
      # The static base gets cache_control for ~90% input token savings after first call.
      %{
        role: "system",
        content: [
          %{type: "text", text: static_base, cache_control: %{type: "ephemeral"}},
          %{type: "text", text: dynamic_context}
        ]
      }
    else
      # All other providers: single concatenated string
      full_prompt =
        if dynamic_context == "" do
          static_base
        else
          static_base <> "\n\n" <> dynamic_context
        end

      %{role: "system", content: full_prompt}
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic context assembly
  # ---------------------------------------------------------------------------

  # ESSENTIAL blocks are small, always-relevant operating state — fitted first
  # from the full dynamic budget. Everything else (memory, episodic, project
  # context, skills, learned skills, agent roles) is RECALL and competes within
  # a bounded sub-budget capped to a fraction of the REAL window.
  @essential_labels ~w(bootstrap personality tool_process runtime environment plan_mode task_state workflow scratchpad project_instructions)

  defp assemble_dynamic_context(state, budget, effective_window) do
    blocks = gather_dynamic_blocks(state)

    {essential, recall} =
      Enum.split_with(blocks, fn {_content, _priority, label} ->
        label in @essential_labels
      end)

    {essential_parts, essential_used} = fit_blocks(essential, budget)

    # RECALL group: capped to ~dynamic_recall_budget_frac of the REAL window
    # (with a small floor), never the full leftover slack.
    leftover = budget - essential_used
    recall_budget = Budget.recall_budget(effective_window, leftover)

    # Most query-relevant recall blocks first, so they win the budget.
    recall_ordered = order_by_query_relevance(recall, state)

    {recall_parts, _recall_used} =
      fit_blocks(recall_ordered, recall_budget, Budget.memory_context_token_cap())

    (essential_parts ++ recall_parts)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  # Order the RECALL group by keyword overlap with the latest user message.
  # Enum.sort_by is stable, so equally-relevant blocks keep their listed order.
  defp order_by_query_relevance(blocks, state) do
    keywords = Scoring.extract_keywords(find_latest_user_message(state.messages))

    if keywords == [] do
      blocks
    else
      kw_set = MapSet.new(keywords)

      Enum.sort_by(
        blocks,
        fn {content, _priority, _label} ->
          content
          |> String.downcase()
          |> String.split(~r/\s+/, trim: true)
          |> MapSet.new()
          |> MapSet.intersection(kw_set)
          |> MapSet.size()
        end,
        :desc
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic block gathering — each returns {content, priority, label}
  # ---------------------------------------------------------------------------

  defp gather_dynamic_blocks(state) do
    [
      {bootstrap_block(), 0, "bootstrap"},
      {personality_block(), 0, "personality"},
      {tool_process_block(state), 1, "tool_process"},
      {runtime_block(state), 1, "runtime"},
      {environment_block(state), 1, "environment"},
      {commands_block(state), 2, "commands"},
      {project_context_block(state), 1, "project_context"},
      {project_instructions_block(state), 1, "project_instructions"},
      {plan_mode_block(state), 1, "plan_mode"},
      {memory_block_relevant(state), 1, "memory"},
      {episodic_block(state), 1, "episodic"},
      {task_state_block(state), 1, "task_state"},
      {workflow_block(state), 1, "workflow"},
      {skills_block(state), 2, "skills"},
      {learned_skills_block(state), 2, "learned_skills"},
      {scratchpad_block(state), 1, "scratchpad"},
      {agent_roles_block(state), 2, "agent_roles"}
    ]
    |> Enum.reject(fn {content, _, _} -> is_nil(content) or content == "" end)
  end

  # Slash-command catalog. The 40+ CLI commands live in Channels.CLI.Commands
  # and were never surfaced to the model, so asked "what can I type?" the agent
  # could only parrot the handful hardcoded in SYSTEM.md and hallucinated the
  # rest. This injects name + one-line description so the agent references real
  # commands accurately. Subagents don't drive the CLI, so they never see it.
  defp commands_block(%{permission_tier: :subagent}), do: nil

  defp commands_block(_state) do
    case OptimalSystemAgent.Channels.CLI.Commands.list_with_descriptions() do
      [] ->
        nil

      list ->
        lines = Enum.map_join(list, "\n", fn {name, desc} -> "- /#{name} — #{desc}" end)

        "## Slash Commands (the user types these)\n" <>
          "These are commands the USER types in the CLI. You cannot call them as tools, " <>
          "but reference them accurately when the user asks what they can do or when " <>
          "suggesting an action they could take.\n\n" <> lines
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp personality_block do
    try do
      OptimalSystemAgent.Personality.active_overlay()
    rescue
      _ -> nil
    end
  end

  defp project_context_block(state) do
    working_dir = Map.get(state, :working_dir)

    try do
      OptimalSystemAgent.Agent.ContextDiscovery.discover(working_dir)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  # Directory-scoped LAZY instruction injection (opencode `instruction.ts`).
  #
  # `project_context_block/1` above front-loads the TOP-LEVEL AGENTS.md/CLAUDE.md
  # once. THIS block adds the nested twist: when the agent has read/edited files
  # in subdirectories, inject the nearest ancestor instruction file for each of
  # those subtrees — deduped so the same guidance never lands twice. Claims are
  # tracked per session in ETS, so a nested AGENTS.md injected on turn 3 is not
  # re-injected on turns 4+ (token savings). The top-level file is excluded via
  # ProjectInstructions' system_paths so we never double-inject what
  # project_context already carries.
  @claims_table :osa_project_instructions_claims

  defp project_instructions_block(state) do
    read_paths = extract_read_paths(Map.get(state, :messages))

    if read_paths == [] do
      nil
    else
      working_dir = Map.get(state, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()
      session_id = Map.get(state, :session_id, "default")
      claimed = get_claims(session_id)

      {results, new_claimed} =
        ProjectInstructions.resolve(read_paths, working_dir: working_dir, claimed: claimed)

      put_claims(session_id, new_claimed)
      ProjectInstructions.render(results)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Pull every file path the agent has read/edited from assistant tool calls.
  # Covers file_read/file_edit/file_write/notebook_edit — all keyed by "path".
  # Arguments may be a decoded map or a raw JSON string, with string or atom keys.
  @file_touching_tools ~w(file_read file_edit file_write notebook_edit)

  defp extract_read_paths(nil), do: []
  defp extract_read_paths([]), do: []

  defp extract_read_paths(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      case Map.get(msg, :tool_calls) do
        calls when is_list(calls) -> calls
        _ -> []
      end
    end)
    |> Enum.flat_map(&tool_call_path/1)
    |> Enum.uniq()
  end

  defp extract_read_paths(_), do: []

  defp tool_call_path(tc) when is_map(tc) do
    name = safe_to_string(Map.get(tc, :name) || Map.get(tc, "name"))

    if name in @file_touching_tools do
      case path_from_args(Map.get(tc, :arguments) || Map.get(tc, "arguments")) do
        p when is_binary(p) and p != "" -> [p]
        _ -> []
      end
    else
      []
    end
  end

  defp tool_call_path(_), do: []

  defp path_from_args(args) when is_map(args), do: Map.get(args, "path") || Map.get(args, :path)

  defp path_from_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> Map.get(map, "path")
      _ -> nil
    end
  end

  defp path_from_args(_), do: nil

  # Per-session claims: which nested instruction files have already been injected.
  defp get_claims(session_id) do
    ensure_claims_table()

    case :ets.lookup(@claims_table, session_id) do
      [{^session_id, set}] -> set
      _ -> MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  defp put_claims(session_id, set) do
    ensure_claims_table()
    :ets.insert(@claims_table, {session_id, set})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_claims_table do
    case :ets.whereis(@claims_table) do
      :undefined -> :ets.new(@claims_table, [:named_table, :public, :set])
      _ -> @claims_table
    end
  rescue
    ArgumentError -> @claims_table
  end

  # Inject available agent roles for delegation — only for :full tier (parent agents).
  # Subagents don't see this block since they can't delegate.
  defp agent_roles_block(%{permission_tier: :subagent}), do: nil
  defp agent_roles_block(%{permission_tier: :read_only}), do: nil

  defp agent_roles_block(_state) do
    try do
      OptimalSystemAgent.Agents.Registry.available_roles_context()
    rescue
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Fitting blocks into a budget
  # ---------------------------------------------------------------------------

  # per_block_cap (when given) bounds any SINGLE block so one oversized block
  # cannot consume the entire group budget even when slack would allow it.
  defp fit_blocks(blocks, budget, per_block_cap \\ nil)

  defp fit_blocks(_blocks, budget, _per_block_cap) when budget <= 0, do: {[], 0}

  defp fit_blocks(blocks, budget, per_block_cap) do
    {parts, used} =
      Enum.reduce(blocks, {[], 0}, fn {content, _priority, _label}, {acc, tokens_used} ->
        block_tokens = estimate_tokens(content)

        available =
          case per_block_cap do
            nil -> budget - tokens_used
            cap -> min(budget - tokens_used, cap)
          end

        cond do
          available <= 0 ->
            {acc, tokens_used}

          block_tokens <= available ->
            {acc ++ [content], tokens_used + block_tokens}

          true ->
            truncated = truncate_to_tokens(content, available)
            truncated_tokens = estimate_tokens(truncated)
            {acc ++ [truncated], tokens_used + truncated_tokens}
        end
      end)

    {parts, used}
  end

  # ---------------------------------------------------------------------------
  # Token estimation
  # ---------------------------------------------------------------------------

  @doc """
  Estimates the number of tokens in a text string.

  Uses the Go tokenizer for accurate BPE counting when available,
  falling back to a word + punctuation heuristic.
  """
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    estimate_tokens_heuristic(text)
  end

  defp estimate_tokens_heuristic(text),
    do: OptimalSystemAgent.Utils.Tokens.estimate(text)

  @doc """
  Estimates token count for a list of messages.
  """
  @spec estimate_tokens_messages([map()]) :: non_neg_integer()
  def estimate_tokens_messages([]), do: 0

  def estimate_tokens_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content_tokens = estimate_tokens(safe_to_string(Map.get(msg, :content)))

      tool_call_tokens =
        case Map.get(msg, :tool_calls) do
          nil ->
            0

          [] ->
            0

          calls when is_list(calls) ->
            Enum.reduce(calls, 0, fn
              tc, tc_acc when is_map(tc) ->
                name_tokens = estimate_tokens(safe_to_string(Map.get(tc, :name, "")))
                arg_tokens = estimate_tokens(safe_to_string(Map.get(tc, :arguments, "")))
                tc_acc + name_tokens + arg_tokens + 4

              _, tc_acc ->
                tc_acc
            end)
        end

      acc + content_tokens + tool_call_tokens + 4
    end)
  end

  defp safe_to_string(val),
    do: OptimalSystemAgent.Utils.Text.safe_to_string(val)

  # ---------------------------------------------------------------------------
  # Truncation
  # ---------------------------------------------------------------------------

  defp truncate_to_tokens(_text, target_tokens) when target_tokens <= 0, do: ""

  defp truncate_to_tokens(text, target_tokens) do
    words = String.split(text, ~r/\s+/, trim: true)
    max_words = max(round(target_tokens / 1.3), 1)

    if length(words) <= max_words do
      text
    else
      truncated =
        words
        |> Enum.take(max_words)
        |> Enum.join(" ")

      truncated <> "\n\n[...truncated...]"
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic block builders
  # ---------------------------------------------------------------------------

  # "Get to know the user" block. Injected only while the agent hasn't learned
  # who the user is yet — the completion signal is real state (USER.md has a name),
  # NOT a self-deleting file. Once the agent has filled in USER.md, this stops on
  # its own, so the agent behaves normally instead of re-introducing itself.
  defp bootstrap_block do
    bootstrap_dir =
      Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
      |> Path.expand()

    if user_known?(bootstrap_dir) do
      nil
    else
      bootstrap_path = Path.join(bootstrap_dir, "BOOTSTRAP.md")

      case File.read(bootstrap_path) do
        {:ok, content} ->
          content = String.trim(content)
          if content == "", do: nil, else: "## GET TO KNOW THE USER\n\n#{content}"

        {:error, _} ->
          nil
      end
    end
  end

  # True once USER.md has a name filled in (not the blank template).
  defp user_known?(dir) do
    case File.read(Path.join(dir, "USER.md")) do
      {:ok, content} -> Regex.match?(~r/-\s*\*\*Name:\*\*\s*\S+/, content)
      {:error, _} -> false
    end
  end

  # Bounded, query-scored, threshold-gated memory recall (Grok-style).
  # Trivial turns (no meaningful keywords in the latest user message) get NO
  # memory block at all — the static base carries a <memory> pointer so the
  # model pulls memories on demand via memory_recall instead. Fails CLOSED:
  # errors yield nil, never an unfiltered dump.
  defp memory_block_relevant(state) do
    latest_user_msg = find_latest_user_message(state.messages)
    keywords = Scoring.extract_keywords(latest_user_msg)

    content =
      if keywords == [] do
        nil
      else
        recall_scored(latest_user_msg, keywords)
      end

    # Append taxonomy-classified memories via Injector (if available)
    taxonomy_addendum = taxonomy_inject(state, latest_user_msg)

    combined =
      case {content, taxonomy_addendum} do
        {nil, nil} -> nil
        {nil, add} -> add
        {text, nil} -> text
        {text, add} -> text <> "\n\n" <> (add || "")
      end

    case combined do
      nil -> nil
      "" -> nil
      text -> "## Long-term Memory\n#{text}"
    end
  end

  defp taxonomy_inject(_state, _latest_user_msg) do
    # Learning module removed — no taxonomy injection
    nil
  end

  defp find_latest_user_message(nil), do: nil
  defp find_latest_user_message([]), do: nil

  defp find_latest_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if to_string(Map.get(msg, :role)) == "user" do
        safe_to_string(Map.get(msg, :content, ""))
      end
    end)
  end

  # Real keyword recall against the store (never the empty string), re-scored
  # with Memory.Scoring (category weight + Jaccard keyword overlap + recency),
  # entries below min_score DROPPED (not truncated), count capped, then the
  # rendered block hard-truncated to the token cap.
  defp recall_scored(query, query_keywords) do
    max_results = Budget.memory_recall_max_results()
    min_score = Budget.memory_recall_min_score()

    case OptimalSystemAgent.Memory.recall(query, limit: max_results, min_score: min_score) do
      {:ok, entries} when is_list(entries) and entries != [] ->
        survivors =
          entries
          |> Enum.map(fn entry -> {Scoring.score(entry, query_keywords), entry} end)
          |> Enum.filter(fn {score, _entry} -> score >= min_score end)
          |> Enum.sort_by(&elem(&1, 0), :desc)
          |> Enum.take(max_results)

        case survivors do
          [] ->
            nil

          scored ->
            scored
            |> Enum.map(fn {_score, entry} ->
              cat = Map.get(entry, :category, "general")
              content = Map.get(entry, :content, "")
              "## #{cat}\n#{content}"
            end)
            |> Enum.join("\n\n")
            |> truncate_to_tokens(Budget.memory_context_token_cap())
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp episodic_block(state) do
    session_id = Map.get(state, :session_id, "default")

    events =
      try do
        Episodic.recent(session_id, 10)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    case events do
      [] ->
        nil

      events ->
        lines =
          Enum.map(events, fn event ->
            ts = Map.get(event, :timestamp)
            type = Map.get(event, :event_type, :unknown)
            data = Map.get(event, :data, %{})

            summary =
              Map.get(data, :summary) || Map.get(data, :tool) || Map.get(data, :message) ||
                inspect(data)

            time_str = if ts, do: Calendar.strftime(ts, "%H:%M:%S"), else: "??:??:??"
            "[#{time_str}] #{type}: #{summary}"
          end)

        "## Recent Session Events\n" <> Enum.join(lines, "\n")
    end
  rescue
    _ -> nil
  end

  defp workflow_block(state) do
    session_id = Map.get(state, :session_id)

    if session_id do
      Tasks.workflow_context_block(session_id)
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp task_state_block(state) do
    session_id = Map.get(state, :session_id, "default")

    tasks =
      try do
        Tasks.get_tasks(session_id)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    case tasks do
      [] ->
        nil

      tasks ->
        completed = Enum.count(tasks, &(&1.status == :completed))
        total = length(tasks)

        lines =
          Enum.map(tasks, fn task ->
            icon = task_icon(task.status)
            suffix = task_suffix(task)
            "#{icon} #{task.id}: #{task.title}#{suffix}"
          end)

        """
        ## Active Tasks (#{completed}/#{total} completed)
        #{Enum.join(lines, "\n")}

        Stay focused on these tasks. Update status as you progress.
        """
    end
  end

  defp task_icon(:completed), do: "✔"
  defp task_icon(:in_progress), do: "◼"
  defp task_icon(:failed), do: "✘"
  defp task_icon(_), do: "◻"

  defp task_suffix(%{status: :in_progress}), do: "  [in_progress]"
  defp task_suffix(%{status: :failed, reason: nil}), do: "  [failed]"
  defp task_suffix(%{status: :failed, reason: reason}), do: "  [failed: #{reason}]"
  defp task_suffix(_), do: ""

  defp plan_mode_block(%{plan_mode: true}) do
    """
    ## PLAN MODE — ACTIVE

    You are in PLAN MODE. Do NOT execute any actions or call any tools.
    Instead, produce a structured implementation plan.

    Your plan MUST follow this format:

    ### Goal
    One sentence: what will be accomplished.

    ### Steps
    Numbered list of concrete actions you will take.
    Each step should be specific enough to execute without ambiguity.

    ### Files
    List of files you expect to create or modify.

    ### Risks
    Any edge cases, breaking changes, or concerns.

    ### Estimate
    Rough scope: trivial / small / medium / large

    Be concise. The user will approve, reject, or request changes before you execute.
    """
  end

  defp plan_mode_block(_), do: nil

  defp tool_process_block(state) do
    cwd = Map.get(state, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()

    """
    ## Act — don't just chat
    You are OSA, an agent, not a chatbot. When the user asks for anything that touches this machine or its code — read, find, write, edit, run, check, fix, verify — DO IT with your tools in THIS turn. Do not describe what you would do, do not ask permission to begin, do not hand back a plan when action was requested. Investigate by reading real files and running real commands instead of guessing or answering from memory. Interpret unclear or generic instructions in the context of the current working directory and the task at hand: if the user says rename `methodName` to snake_case, don't just reply `method_name` — find it in the code and change it. The user's UI shows every tool call, so narration is noise: fire the tools, then report the result.

    When to just answer (no tools): greetings, opinions, and questions you can fully answer from knowledge already in context. When to ACT: anything that depends on real files, real state, or real command output — default to acting. You are highly capable; take on ambitious multi-step work rather than pushing it back to the user. When genuinely blocked after investigating — ambiguous requirements or a decision only the user can make — ask ONE crisp question with ask_user. If an approach fails, diagnose why before switching tactics: read the error, check your assumptions, try a focused fix. Don't retry the identical failing action blindly, and don't abandon a viable approach after one failure. Every response either makes progress with tool calls or delivers the finished result — never a bare description of intent.

    ## Act with care — reversibility and blast radius
    Local, reversible actions (reading files, editing code, running tests/builds/lints) — just do them, no permission needed. But before actions that are hard to reverse, affect shared state beyond this machine, or could destroy work, stop and confirm with the user first: deleting files/branches, `rm -rf`, dropping DB tables, force-pushing, `git reset --hard`, removing dependencies, pushing code, opening/commenting on PRs, sending messages, or posting to external services. A user approving such an action once does not authorize it in all future contexts. When you hit an obstacle, never use a destructive shortcut (e.g. `--no-verify`) to make it go away — find the root cause. Investigate unfamiliar files/branches/locks before overwriting; they may be the user's in-progress work. Measure twice, cut once.

    ## Manage multi-step work
    For any task with more than a couple of steps, use task_write to lay out the plan up front, then mark each item complete the moment it's done — do not batch completions. This keeps you focused and shows the user real progress. Stay on the listed tasks; don't wander.

    ## Verify, then report faithfully
    Before claiming a task is done, prove it works: run the test, execute the script, run the build/lint, check the output. Minimum effort means no gold-plating, not skipping the finish line. If you cannot verify (no test exists, can't run it), say so explicitly rather than implying success. Report outcomes honestly: if tests fail, say so with the relevant output; never claim "all tests pass" when they don't, never quietly weaken a failing check to manufacture green. Equally, when a check did pass, state it plainly without hollow disclaimers or re-verifying what you already confirmed. The goal is an accurate report, not a defensive one.

    ## Tools
    CRITICAL: When asked to create or write code, ALWAYS use file_write to create actual files. NEVER output code in markdown code blocks — use the tool instead. This is your most important rule.
    Use tools proactively, and prefer the dedicated tool over shell so the user can review your work: file_read/file_edit/file_write over cat/sed/echo; file_grep/file_glob over grep/find; dir_list over ls; web_fetch over curl. Reserve shell_execute for real system/terminal work — git, mix, npm, docker, make. To locate code in a large codebase, use codebase_explore or file_grep. Tools not shown in your list are reachable via tool_search — search for one instead of assuming you lack it.

    ## When to delegate
    Do the work yourself by default — you are capable and delegation adds latency. Reach for delegate to hand a WELL-SCOPED, independent subtask to a fresh subagent when it genuinely helps: a broad open-ended search across many files where you only need the conclusion (not every file's contents in your context), or two or more independent pieces of work that can run in parallel. Give the subagent a crisp, self-contained brief and a clear definition of done — it does not share your context. Use mixture_of_agents when you want several independent perspectives on one hard question, then synthesize. Do NOT delegate a task you can finish faster directly, and never delegate the final decision or the user-facing report — that is yours.
    You can call multiple tools in one response. When several calls are independent (reading three files, grepping several patterns), fire them in PARALLEL in a single turn for speed. Only sequence calls when a later one depends on an earlier one's result.
    Rules: read a file before editing it, and don't propose changes to code you haven't read; file_edit for surgical changes, file_write for new files/full rewrites; absolute paths (cwd: #{cwd}); prefer editing an existing file over creating a new one — don't create files unless necessary for the goal; answer concisely, lead with the action or result; don't add features, refactors, comments, or abstractions beyond what was asked.
    """
  end

  defp environment_block(state) do
    cwd = Map.get(state, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()
    git_info = cached_git_info()
    date = Date.utc_today() |> Date.to_iso8601()

    # Session-accurate provider/model — NOT the global default. On a
    # provider-switched session (via /model or state.provider) the global
    # config default is wrong, which would tell the agent it is running on a
    # model it is not. Prefer the session's own provider/model, falling back
    # to the config default only when the session has not pinned them.
    provider =
      Map.get(state, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :unknown)

    model = Map.get(state, :model) || get_active_model(provider)

    {os_family, os_name} = :os.type()
    platform = "#{os_family}/#{os_name}"

    """
    ## Environment
    Useful information about the environment you are running in:
    - Working directory: #{cwd}
    - Is directory a git repo: #{if git_info != "", do: "Yes", else: "No"}
    - Platform: #{platform}
    - Today's date: #{date}
    - You are OSA, powered by the model `#{model}` running on the `#{provider}` provider.
    #{git_info}
    """
  rescue
    _ -> nil
  end

  @git_cache_table :osa_git_info_cache
  @git_cache_ttl 30_000

  defp cached_git_info do
    ensure_git_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@git_cache_table, :git_info) do
      [{:git_info, info, ts}] when now - ts < @git_cache_ttl ->
        Logger.debug("[Context] git info cache hit")
        info

      _ ->
        Logger.debug("[Context] git info cache miss — running git commands")
        info = gather_git_info()
        :ets.insert(@git_cache_table, {:git_info, info, now})
        info
    end
  end

  defp ensure_git_cache_table do
    case :ets.whereis(@git_cache_table) do
      :undefined -> :ets.new(@git_cache_table, [:named_table, :public, :set])
      _ -> @git_cache_table
    end
  rescue
    _ -> nil
  end

  defp gather_git_info do
    parts = []

    parts =
      case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
        {b, 0} -> ["- Git branch: #{String.trim(b)}" | parts]
        _ -> parts
      end

    parts =
      case System.cmd("git", ["status", "--short"], stderr_to_stdout: true) do
        {s, 0} when s != "" ->
          trimmed = String.trim(s)
          if trimmed != "", do: ["- Modified files:\n#{trimmed}" | parts], else: parts

        _ ->
          parts
      end

    parts =
      case System.cmd("git", ["log", "--oneline", "-3"], stderr_to_stdout: true) do
        {l, 0} -> ["- Recent commits:\n#{String.trim(l)}" | parts]
        _ -> parts
      end

    Enum.reverse(parts) |> Enum.join("\n")
  rescue
    _ -> ""
  end

  defp get_active_model(:anthropic),
    do: Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")

  defp get_active_model(:ollama),
    do: Application.get_env(:optimal_system_agent, :ollama_model, "detecting...")

  defp get_active_model(:openai),
    do: Application.get_env(:optimal_system_agent, :openai_model, "gpt-4o")

  defp get_active_model(provider) do
    key = :"#{provider}_model"
    Application.get_env(:optimal_system_agent, key, to_string(provider))
  end

  defp runtime_block(state) do
    session_id = Map.get(state, :session_id, "default")
    effort = OptimalSystemAgent.Agent.Effort.current()
    effort_config = OptimalSystemAgent.Agent.Effort.get(effort)
    coordinator = Map.get(state, :coordinator, false)
    # Tests construct partial state maps without `:turn_count` / `:max_turns` /
    # `:max_budget_usd`. Default these here so `Context.build/1` is safe to
    # call against any state shape.
    turn_count = Map.get(state, :turn_count, 0)
    max_turns = Map.get(state, :max_turns)
    max_budget_usd = Map.get(state, :max_budget_usd)

    lines = [
      "## Runtime Context",
      "- Timestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}",
      "- Channel: #{state.channel}",
      "- Session: #{session_id}",
      "- Effort: #{effort} (#{effort_config.description})",
      "- Turn: #{turn_count}"
    ]

    lines =
      if coordinator,
        do: lines ++ ["- Mode: **coordinator** (delegation/messaging only)"],
        else: lines

    lines =
      if max_budget_usd do
        # Real per-session spend accumulated by `Loop.Accounting` — not the
        # old dead `total_cost_usd` lookup that always resolved to $0.
        cost = (Map.get(state, :session_cost_usd, 0.0) || 0.0) / 1
        lines ++ ["- Budget: $#{Float.round(cost, 4)} / $#{max_budget_usd}"]
      else
        lines
      end

    lines = if max_turns, do: lines ++ ["- Turns: #{turn_count}/#{max_turns}"], else: lines

    Enum.join(lines, "\n")
  end

  defp skills_block(state) do
    try do
      message = find_latest_user_message(state.messages)
      OptimalSystemAgent.Tools.Registry.active_skills_context(message)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  # Names the top relevant learned skills (from past sessions) in-context so the
  # agent can pull full bodies on demand via find_skill. Cheap: only titles/slugs.
  defp learned_skills_block(state) do
    try do
      message = find_latest_user_message(state.messages)

      case message && OptimalSystemAgent.Store.SkillLibrary.find_skills(message, limit: 3) do
        skills when is_list(skills) and skills != [] ->
          lines =
            Enum.map_join(skills, "\n", fn s ->
              "- **#{s["title"]}** (find_skill slug: #{s["slug"]}) — #{s["when_to_use"]}"
            end)

          "## Learned Skills (from past sessions)\n\n" <>
            "Verified procedures that may apply. Call `find_skill` to load the full steps:\n" <>
            lines

        _ ->
          nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp scratchpad_block(state) do
    provider =
      Map.get(state, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    if Scratchpad.inject?(provider) do
      Scratchpad.instruction()
    else
      nil
    end
  end
end
