defmodule OptimalSystemAgent.Agent.Context do
  @moduledoc """
  Token-budgeted priority assembly for the system prompt.

  ## Strategy

  The context builder assembles the system prompt from layered sources, each
  assigned to a priority tier. Instead of blindly concatenating every block,
  it operates within a **token budget**:

      Total budget          = @max_tokens (from config, default 128_000)
      Response reserve      = @response_reserve (4 096 tokens for the LLM reply)
      Conversation reserve  = estimate_tokens(state.messages)
      System prompt budget  = Total - Response reserve - Conversation reserve

  Blocks are assembled in priority order. Each tier has a percentage ceiling
  of the system prompt budget:

      Tier 1 — CRITICAL (always included, no cap)
        Identity block, signal classification, runtime context

      Tier 2 — HIGH (up to 40% of system prompt budget)
        Active skills docs, relevant memories, workflow state

      Tier 3 — MEDIUM (up to 30%)
        Bootstrap files, communication profile, cortex bulletin

      Tier 4 — LOW (remaining budget)
        OS templates, machine addendums, full contact info

  Blocks that exceed their tier allocation are truncated with
  `[...truncated...]`. The builder logs actual token usage at debug level.

  ## Public API

      build(state, signal)        — returns %{messages: [system_msg | conversation]}
      token_budget(state, signal) — returns token usage breakdown map
  """

  require Logger

  alias OptimalSystemAgent.Skills.Registry, as: Skills
  alias OptimalSystemAgent.Signal.Classifier
  alias OptimalSystemAgent.Intelligence.CommProfiler
  alias OptimalSystemAgent.Agent.Workflow
  alias OptimalSystemAgent.Soul

  @response_reserve 4_096

  defp max_tokens, do: Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
  defp tier2_pct, do: Application.get_env(:optimal_system_agent, :tier2_budget_pct, 0.40)
  defp tier3_pct, do: Application.get_env(:optimal_system_agent, :tier3_budget_pct, 0.30)
  # Tier 4 gets whatever is left

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Builds the full message list (system prompt + conversation history) within
  the configured token budget.

  Returns `%{messages: [system_msg | conversation_messages]}`.
  """
  @spec build(map(), Classifier.t() | nil) :: %{messages: [map()]}
  def build(state, signal \\ nil) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    max_tok = max_tokens()
    system_budget = max(max_tok - @response_reserve - conversation_tokens, 2_000)

    system_prompt = assemble_system_prompt(state, signal, system_budget)

    system_tokens = estimate_tokens(system_prompt)
    total_tokens = system_tokens + conversation_tokens + @response_reserve

    Logger.debug(
      "Context.build: system=#{system_tokens} conversation=#{conversation_tokens} " <>
        "reserve=#{@response_reserve} total=#{total_tokens}/#{max_tok} " <>
        "(#{Float.round(total_tokens / max_tok * 100, 1)}%)"
    )

    system_msg = %{role: "system", content: system_prompt}
    %{messages: [system_msg | conversation]}
  end

  @doc """
  Returns a token usage breakdown for debugging purposes.

  When `signal` is nil the signal block is omitted from the calculation.
  """
  @spec token_budget(map(), Classifier.t() | nil) :: map()
  def token_budget(state, signal \\ nil) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    max_tok = max_tokens()
    system_budget = max(max_tok - @response_reserve - conversation_tokens, 2_000)

    # Gather all blocks with priorities to show individual costs
    blocks = gather_blocks(state, signal)

    block_details =
      Enum.map(blocks, fn {content, priority, label} ->
        %{
          label: label,
          priority: priority,
          tokens: estimate_tokens(content || "")
        }
      end)

    system_prompt = assemble_system_prompt(state, signal, system_budget)
    system_tokens = estimate_tokens(system_prompt)
    total_tokens = system_tokens + conversation_tokens + @response_reserve

    %{
      max_tokens: max_tok,
      response_reserve: @response_reserve,
      conversation_tokens: conversation_tokens,
      system_prompt_budget: system_budget,
      system_prompt_actual: system_tokens,
      total_tokens: total_tokens,
      utilization_pct: Float.round(total_tokens / max_tok * 100, 1),
      headroom: max_tok - total_tokens,
      blocks: block_details
    }
  end

  # ---------------------------------------------------------------------------
  # Assembly engine
  # ---------------------------------------------------------------------------

  @doc false
  defp assemble_system_prompt(state, signal, system_budget) do
    blocks = gather_blocks(state, signal)

    # Group by tier
    tier1 = Enum.filter(blocks, fn {_, p, _} -> p == 1 end)
    tier2 = Enum.filter(blocks, fn {_, p, _} -> p == 2 end)
    tier3 = Enum.filter(blocks, fn {_, p, _} -> p == 3 end)
    tier4 = Enum.filter(blocks, fn {_, p, _} -> p == 4 end)

    # Tier 1 is always included in full — compute its cost
    tier1_parts = extract_parts(tier1)
    tier1_tokens = tokens_for_parts(tier1_parts)

    remaining = system_budget - tier1_tokens

    # Tier 2 budget
    tier2_budget = round(system_budget * tier2_pct())
    {tier2_parts, tier2_used} = fit_blocks(tier2, min(tier2_budget, remaining))
    remaining = remaining - tier2_used

    # Tier 3 budget
    tier3_budget = round(system_budget * tier3_pct())
    {tier3_parts, tier3_used} = fit_blocks(tier3, min(tier3_budget, remaining))
    remaining = remaining - tier3_used

    # Tier 4 gets whatever is left
    {tier4_parts, _tier4_used} = fit_blocks(tier4, max(remaining, 0))

    all_parts = tier1_parts ++ tier2_parts ++ tier3_parts ++ tier4_parts

    all_parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  # ---------------------------------------------------------------------------
  # Block gathering — each returns {content, priority_tier, label}
  # ---------------------------------------------------------------------------

  @doc false
  defp gather_blocks(state, signal) do
    [
      # Tier 1 — CRITICAL
      # Soul.system_prompt/1 composes IDENTITY.md + SOUL.md + signal overlay.
      # This replaces the old hard-coded identity_block() AND signal_block()
      # AND the Tier 3 bootstrap_files() — all unified under Soul.
      {Soul.system_prompt(signal), 1, "soul"},
      {tool_process_block(), 1, "tool_process"},
      {runtime_block(state), 1, "runtime"},
      {plan_mode_block(state), 1, "plan_mode"},

      # Tier 2 — HIGH
      {skills_block(), 2, "skills"},
      {memory_block_relevant(state), 2, "memory"},
      {workflow_block(state), 2, "workflow"},

      # Tier 3 — MEDIUM
      {Soul.user_block(), 3, "user_profile"},
      {intelligence_block(state), 3, "communication_profile"},
      {cortex_block(), 3, "cortex_bulletin"},

      # Tier 4 — LOW
      {os_templates_block(), 4, "os_templates"},
      {machines_block(), 4, "machines"}
    ]
    |> Enum.reject(fn {content, _, _} -> is_nil(content) or content == "" end)
  end

  # ---------------------------------------------------------------------------
  # Fitting blocks into a budget
  # ---------------------------------------------------------------------------

  @doc false
  defp fit_blocks(_blocks, budget) when budget <= 0, do: {[], 0}

  defp fit_blocks(blocks, budget) do
    {parts, used} =
      Enum.reduce(blocks, {[], 0}, fn {content, _priority, _label}, {acc, tokens_used} ->
        block_tokens = estimate_tokens(content)
        available = budget - tokens_used

        cond do
          available <= 0 ->
            # No budget left — skip
            {acc, tokens_used}

          block_tokens <= available ->
            # Fits entirely
            {acc ++ [content], tokens_used + block_tokens}

          true ->
            # Truncate to fit
            truncated = truncate_to_tokens(content, available)
            truncated_tokens = estimate_tokens(truncated)
            {acc ++ [truncated], tokens_used + truncated_tokens}
        end
      end)

    {parts, used}
  end

  @doc false
  defp extract_parts(blocks) do
    Enum.map(blocks, fn {content, _, _} -> content end)
  end

  @doc false
  defp tokens_for_parts(parts) do
    parts
    |> Enum.map(&estimate_tokens/1)
    |> Enum.sum()
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
    case OptimalSystemAgent.Go.Tokenizer.count_tokens(text) do
      {:ok, count} -> count
      {:error, _} -> estimate_tokens_heuristic(text)
    end
  catch
    _, _ -> estimate_tokens_heuristic(text)
  end

  @doc false
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

      # Tool calls add tokens for function names and arguments
      tool_call_tokens =
        case Map.get(msg, :tool_calls) do
          nil ->
            0

          [] ->
            0

          calls when is_list(calls) ->
            Enum.reduce(calls, 0, fn tc, tc_acc ->
              name_tokens = estimate_tokens(safe_to_string(Map.get(tc, :name, "")))
              arg_tokens = estimate_tokens(safe_to_string(Map.get(tc, :arguments, "")))
              # overhead per tool call
              tc_acc + name_tokens + arg_tokens + 4
            end)
        end

      # Per-message overhead (role tag, separators)
      acc + content_tokens + tool_call_tokens + 4
    end)
  end

  defp safe_to_string(val),
    do: OptimalSystemAgent.Utils.Text.safe_to_string(val)

  # ---------------------------------------------------------------------------
  # Truncation
  # ---------------------------------------------------------------------------

  @doc false
  defp truncate_to_tokens(_text, target_tokens) when target_tokens <= 0, do: ""

  defp truncate_to_tokens(text, target_tokens) do
    words = String.split(text, ~r/\s+/, trim: true)

    # Rough: target_tokens / 1.3 gives approximate word count
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
  # Block builders
  # ---------------------------------------------------------------------------

  # identity_block/0 removed — replaced by Soul.system_prompt/1 which composes
  # IDENTITY.md + SOUL.md + signal overlay dynamically.

  # bootstrap_files/0 removed — IDENTITY.md and SOUL.md are now loaded by
  # Soul module (Tier 1). USER.md is served via Soul.user_block() (Tier 3).

  @doc false
  defp memory_block_relevant(state) do
    # Attempt relevance-based memory retrieval using the latest user message.
    # Falls back to full recall if no user messages or if relevance search unavailable.
    latest_user_msg = find_latest_user_message(state.messages)

    content =
      if latest_user_msg do
        try do
          recall_relevant(latest_user_msg)
        rescue
          _ -> full_recall()
        end
      else
        full_recall()
      end

    case content do
      nil -> nil
      "" -> nil
      text -> "## Long-term Memory\n#{text}"
    end
  end

  @doc false
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

  @doc false
  defp recall_relevant(query) do
    # Retrieve full memory, then extract lines relevant to the query.
    # This is a lightweight keyword-overlap relevance filter — not semantic
    # search, but far better than dumping the entire MEMORY.md.
    full = full_recall()

    case full do
      nil ->
        nil

      "" ->
        nil

      text ->
        query_words =
          query
          |> String.downcase()
          |> String.split(~r/\s+/, trim: true)
          |> Enum.reject(&(String.length(&1) < 3))
          |> MapSet.new()

        if MapSet.size(query_words) == 0 do
          # No meaningful query words — return full memory
          text
        else
          sections = String.split(text, ~r/\n(?=## )/, trim: true)

          relevant =
            sections
            |> Enum.filter(fn section ->
              section_words =
                section
                |> String.downcase()
                |> String.split(~r/\s+/, trim: true)
                |> MapSet.new()

              overlap = MapSet.intersection(query_words, section_words) |> MapSet.size()
              # Keep section if it shares at least 2 words or 20% of query words
              overlap >= 2 or overlap >= MapSet.size(query_words) * 0.2
            end)

          case relevant do
            # No matches — include everything rather than nothing
            [] -> text
            _ -> Enum.join(relevant, "\n\n")
          end
        end
    end
  end

  @doc false
  defp full_recall do
    try do
      content = OptimalSystemAgent.Agent.Memory.recall()
      if content == "", do: nil, else: content
    rescue
      _ -> nil
    end
  end

  @doc false
  defp machines_block do
    addendums = OptimalSystemAgent.Machines.prompt_addendums()

    case addendums do
      [] -> nil
      list -> Enum.join(list, "\n\n")
    end
  rescue
    _ -> nil
  end

  @doc false
  defp os_templates_block do
    addendums = OptimalSystemAgent.OS.Registry.prompt_addendums()

    case addendums do
      [] -> nil
      list -> Enum.join(list, "\n\n")
    end
  rescue
    _ -> nil
  end

  # signal_block/1 removed — signal overlay is now integrated into
  # Soul.system_prompt/1 which includes mode/genre-specific behavior guidance.

  @doc false
  defp skills_block do
    skills = Skills.list_skill_docs()

    tools =
      try do
        Skills.list_tools()
      rescue
        _ -> []
      end

    case skills do
      [] ->
        nil

      list ->
        # Index tools by name for parameter lookup
        tool_index = Map.new(tools, fn tool -> {tool.name, tool} end)

        docs =
          Enum.map(list, fn {name, desc} ->
            base = "- **#{name}**: #{desc}"

            case Map.get(tool_index, name) do
              %{parameters: params} when is_map(params) and map_size(params) > 0 ->
                param_info = format_parameters(params)
                if param_info != "", do: base <> "\n  " <> param_info, else: base

              _ ->
                base
            end
          end)

        "## Available Skills\n#{Enum.join(docs, "\n")}"
    end
  rescue
    _ -> nil
  end

  @doc false
  defp format_parameters(params) do
    properties = Map.get(params, "properties", %{})
    required = MapSet.new(Map.get(params, "required", []))

    if map_size(properties) == 0 do
      ""
    else
      props =
        Enum.map(properties, fn {name, spec} ->
          type = Map.get(spec, "type", "any")
          req = if MapSet.member?(required, name), do: " (required)", else: ""
          desc = Map.get(spec, "description", "")
          desc_part = if desc != "", do: " — #{desc}", else: ""
          "`#{name}` (#{type}#{req})#{desc_part}"
        end)

      "Parameters: #{Enum.join(props, ", ")}"
    end
  end

  @doc false
  defp workflow_block(state) do
    # Query the Workflow GenServer for active workflow context.
    # Falls back to nil if the GenServer is not running or has no active workflow.
    session_id = Map.get(state, :session_id)

    if session_id do
      Workflow.context_block(session_id)
    else
      nil
    end
  rescue
    _ -> nil
  end

  @doc false
  defp intelligence_block(state) do
    parts = []

    parts =
      case state.user_id && CommProfiler.get_profile(state.user_id) do
        {:ok, profile} when not is_nil(profile) ->
          [format_comm_profile(profile) | parts]

        _ ->
          parts
      end

    case parts do
      [] -> nil
      _ -> "## Communication Intelligence\n" <> Enum.join(Enum.reverse(parts), "\n\n")
    end
  rescue
    _ -> nil
  end

  @doc false
  defp format_comm_profile(profile) do
    topics = Map.get(profile, :topics, []) |> Enum.join(", ")

    """
    User communication profile:
    - Formality level: #{Map.get(profile, :formality, "unknown")}
    - Average message length: #{Map.get(profile, :avg_length, "unknown")}
    - Common topics: #{topics}

    Adapt your tone and detail level to match this user's communication style.
    """
  end

  @doc false
  defp cortex_block do
    case OptimalSystemAgent.Agent.Cortex.bulletin() do
      nil -> nil
      "" -> nil
      bulletin when is_binary(bulletin) -> "## Memory Bulletin\n#{bulletin}"
    end
  rescue
    _ -> nil
  end

  @doc false
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

  @doc false
  defp tool_process_block do
    cwd = File.cwd!()

    """
    ## How to Use Tools

    You have tools available. Use them proactively to accomplish tasks. Follow this process:

    ### Process

    1. **Read the user's request.** Understand what they need.
    2. **Decide if tools are needed.** Simple conversation = no tools. Tasks involving files, commands, search, or memory = use tools.
    3. **Call ONE tool at a time.** Wait for the result before deciding what to do next.
    4. **Use the result.** Read the tool output, then decide: call another tool, or respond to the user.
    5. **Respond when done.** Summarize what you did and the results.

    ### When to Use Each Tool

    - **file_read** — When the user mentions a file, asks about code, or you need to understand existing content. Always read before modifying.
      Example: User says "fix the bug in main.py" → call file_read with path "main.py" first.

    - **file_write** — When you need to create or modify a file. Read the file first if it exists.
      Example: After reading and understanding a file, write the fixed version.

    - **shell_execute** — When you need to run commands: install packages, run tests, check git status, list files, compile code.
      Example: User says "run the tests" → call shell_execute with command "mix test" or "npm test".
      Example: User says "what files are here" → call shell_execute with command "ls -la".

    - **web_search** — When you need current information, documentation, or answers to factual questions.
      Example: User asks about a library API → search for it.

    - **memory_save** — When the user tells you something important to remember, or you learn a preference.
      Example: User says "I always use tabs" → save that preference.

    - **orchestrate** — Only for complex multi-part tasks that benefit from parallel sub-agents.

    ### When NOT to Use Tools

    - Greetings and casual conversation ("hey", "thanks", "what's up")
    - Questions you can answer from your training knowledge
    - Opinions or recommendations that don't require looking at files

    ### Important Rules

    - **Always read before writing.** Never modify a file you haven't read first.
    - **One tool call per turn.** Call one tool, get the result, then decide the next step.
    - **Use absolute paths.** The current working directory is: #{cwd}
    - **Show your work.** After using tools, tell the user what you found or did.
    - **Be proactive.** If the user asks to "fix" something, read the file, find the issue, fix it, and verify — don't just suggest changes.

    ### Sequential Workflow Example

    User: "There's a bug in lib/app.ex, the function crashes on empty input"

    Step 1: Call file_read(path: "lib/app.ex") → read the file
    Step 2: Identify the bug in the code
    Step 3: Call file_write(path: "lib/app.ex", content: <fixed code>) → write the fix
    Step 4: Call shell_execute(command: "mix test") → verify the fix works
    Step 5: Tell the user what was wrong and how you fixed it
    """
  end

  @doc false
  defp runtime_block(state) do
    """
    ## Runtime Context
    - Timestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    - Channel: #{state.channel}
    - Session: #{state.session_id}
    """
  end
end
