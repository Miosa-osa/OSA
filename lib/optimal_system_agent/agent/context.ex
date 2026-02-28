defmodule OptimalSystemAgent.Agent.Context do
  @moduledoc """
  Two-tier token-budgeted system prompt assembly.

  ## Architecture (v2)

  The context builder operates in two tiers:

      Tier 1 — Static Base (cached, from Soul.static_base/0)
        SYSTEM.md interpolated with {{TOOL_DEFINITIONS}}, {{RULES}}, {{USER_PROFILE}}.
        Cached in persistent_term. Never recomputed within a session.

      Tier 2 — Dynamic Context (per-request, token-budgeted)
        Signal overlay, environment, runtime, plan mode, memory, tasks,
        workflow, communication profile, cortex bulletin, OS templates, machines.
        Assembled fresh per call with priority-based fitting.

  ## Token Budget

      dynamic_budget = max_tokens - static_tokens - conversation_tokens - reserve
      Priority 1 blocks: always included (signal, env, runtime, plan mode)
      Priority 2 blocks: budget-fitted (memory, tasks, workflow)
      Priority 3 blocks: budget-fitted (comm profile, cortex)
      Priority 4 blocks: remaining budget (OS templates, machines)

  ## Provider Cache Hints

  For Anthropic, the system message is split into 2 content blocks:
    - Static base with `cache_control: %{type: "ephemeral"}` (~90% cache hit)
    - Dynamic context (per-request, uncached)

  ## Public API

      build(state, signal)        — returns %{messages: [system_msg | conversation]}
      token_budget(state, signal) — returns token usage breakdown map
  """

  require Logger

  alias OptimalSystemAgent.Signal.Classifier
  alias OptimalSystemAgent.Intelligence.CommProfiler
  alias OptimalSystemAgent.Agent.Workflow
  alias OptimalSystemAgent.Agent.TaskTracker
  alias OptimalSystemAgent.PromptLoader
  alias OptimalSystemAgent.Soul

  @response_reserve 4_096

  defp max_tokens, do: Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
  defp tier2_pct, do: Application.get_env(:optimal_system_agent, :tier2_budget_pct, 0.40)
  defp tier3_pct, do: Application.get_env(:optimal_system_agent, :tier3_budget_pct, 0.30)
  # Priority 4 gets whatever is left

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

    # Tier 1: Cached static base
    static_base = Soul.static_base()
    static_tokens = Soul.static_token_count()

    # Tier 2: Dynamic context
    dynamic_budget = max(max_tok - @response_reserve - conversation_tokens - static_tokens, 1_000)
    dynamic_context = assemble_dynamic_context(state, signal, dynamic_budget)

    dynamic_tokens = estimate_tokens(dynamic_context)
    total_tokens = static_tokens + dynamic_tokens + conversation_tokens + @response_reserve

    Logger.debug(
      "Context.build: static=#{static_tokens} dynamic=#{dynamic_tokens} " <>
        "conversation=#{conversation_tokens} reserve=#{@response_reserve} " <>
        "total=#{total_tokens}/#{max_tok} (#{Float.round(total_tokens / max_tok * 100, 1)}%)"
    )

    system_msg = build_system_message(static_base, dynamic_context)
    %{messages: [system_msg | conversation]}
  end

  @doc """
  Returns a token usage breakdown for debugging purposes.
  """
  @spec token_budget(map(), Classifier.t() | nil) :: map()
  def token_budget(state, signal \\ nil) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    max_tok = max_tokens()
    static_tokens = Soul.static_token_count()

    # Gather dynamic blocks for individual cost breakdown
    blocks = gather_dynamic_blocks(state, signal)

    block_details =
      Enum.map(blocks, fn {content, priority, label} ->
        %{
          label: label,
          priority: priority,
          tokens: estimate_tokens(content || "")
        }
      end)

    dynamic_budget = max(max_tok - @response_reserve - conversation_tokens - static_tokens, 1_000)
    dynamic_context = assemble_dynamic_context(state, signal, dynamic_budget)
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

  defp build_system_message(static_base, dynamic_context) do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)

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

  defp assemble_dynamic_context(state, signal, budget) do
    blocks = gather_dynamic_blocks(state, signal)

    # Group by priority
    p1 = Enum.filter(blocks, fn {_, p, _} -> p == 1 end)
    p2 = Enum.filter(blocks, fn {_, p, _} -> p == 2 end)
    p3 = Enum.filter(blocks, fn {_, p, _} -> p == 3 end)
    p4 = Enum.filter(blocks, fn {_, p, _} -> p == 4 end)

    # Priority 1: always included in full
    p1_parts = extract_parts(p1)
    p1_tokens = tokens_for_parts(p1_parts)

    remaining = budget - p1_tokens

    # Priority 2: up to tier2_pct of total dynamic budget
    p2_budget = round(budget * tier2_pct())
    {p2_parts, p2_used} = fit_blocks(p2, min(p2_budget, remaining))
    remaining = remaining - p2_used

    # Priority 3: up to tier3_pct of total dynamic budget
    p3_budget = round(budget * tier3_pct())
    {p3_parts, p3_used} = fit_blocks(p3, min(p3_budget, remaining))
    remaining = remaining - p3_used

    # Priority 4: whatever is left
    {p4_parts, _p4_used} = fit_blocks(p4, max(remaining, 0))

    all_parts = p1_parts ++ p2_parts ++ p3_parts ++ p4_parts

    all_parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  # ---------------------------------------------------------------------------
  # Dynamic block gathering — each returns {content, priority, label}
  # ---------------------------------------------------------------------------

  defp gather_dynamic_blocks(state, signal) do
    [
      # Priority 1 — always included
      {signal_overlay_block(signal), 1, "signal_overlay"},
      {runtime_block(state), 1, "runtime"},
      {environment_block(state), 1, "environment"},
      {plan_mode_block(state), 1, "plan_mode"},

      # Priority 2 — budget-fitted
      {memory_block_relevant(state), 2, "memory"},
      {task_state_block(state), 2, "task_state"},
      {workflow_block(state), 2, "workflow"},

      # Priority 3 — budget-fitted
      {intelligence_block(state), 3, "communication_profile"},
      {cortex_block(), 3, "cortex_bulletin"},

      # Priority 4 — remaining budget
      {os_templates_block(), 4, "os_templates"},
      {machines_block(), 4, "machines"}
    ]
    |> Enum.reject(fn {content, _, _} -> is_nil(content) or content == "" end)
  end

  # ---------------------------------------------------------------------------
  # Signal overlay (moved from Soul — dynamic per-request content)
  # ---------------------------------------------------------------------------

  @mode_behavior_defaults %{
    execute:
      "**Mode: EXECUTE** — Be concise and action-oriented. Do the thing, confirm it's done. No preamble.",
    build: "**Mode: BUILD** — Create with quality. Show your work. Structure the output.",
    analyze: "**Mode: ANALYZE** — Be thorough and data-driven. Show reasoning. Use structure.",
    maintain:
      "**Mode: MAINTAIN** — Be careful and precise. Check before changing. Explain impact.",
    assist: "**Mode: ASSIST** — Guide and explain. Match the user's depth. Be genuinely helpful."
  }

  @genre_behavior_defaults %{
    direct: "**Genre: DIRECT** — The user is commanding. Respond with action, not explanation.",
    inform:
      "**Genre: INFORM** — The user is sharing information. Acknowledge, process, note for later.",
    commit: "**Genre: COMMIT** — The user is committing to something. Confirm and track it.",
    decide: "**Genre: DECIDE** — The user needs a decision. Validate, recommend, then execute.",
    express: "**Genre: EXPRESS** — The user is expressing emotion. Lead with empathy, then help."
  }

  defp signal_overlay_block(nil), do: nil

  defp signal_overlay_block(%{mode: mode, genre: genre, weight: weight}) do
    mode_str = mode |> to_string() |> String.upcase()
    genre_str = genre |> to_string() |> String.upcase()

    mode_guidance = mode_behavior(mode)
    genre_guidance = genre_behavior(genre)

    weight_guidance =
      cond do
        weight < 0.3 ->
          "This is a lightweight signal. Keep your response brief and natural."

        weight > 0.8 ->
          "This is a high-density signal. Give it your full attention and thoroughness."

        true ->
          ""
      end

    """
    ## Active Signal: #{mode_str} × #{genre_str} (weight: #{Float.round(weight, 2)})

    **IMPORTANT: This signal classification is internal behavioral guidance only. Do NOT mention signal mode, genre, weight, or classification in your response. Never echo or reference "Active Signal" text. Just respond naturally.**

    #{mode_guidance}

    #{genre_guidance}

    #{weight_guidance}
    """
    |> String.trim()
  end

  defp signal_overlay_block(_), do: nil

  defp mode_behavior(mode) do
    case lookup_behavior(PromptLoader.get(:mode_behaviors), mode) do
      nil -> Map.get(@mode_behavior_defaults, mode, "")
      text -> text
    end
  end

  defp genre_behavior(genre) do
    case lookup_behavior(PromptLoader.get(:genre_behaviors), genre) do
      nil -> Map.get(@genre_behavior_defaults, genre, "")
      text -> text
    end
  end

  defp lookup_behavior(nil, _key), do: nil

  defp lookup_behavior(content, key) when is_binary(content) do
    key_str = to_string(key)

    content
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] ->
          if String.trim(k) == key_str do
            v |> String.trim() |> String.trim("\"")
          end

        _ ->
          nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Fitting blocks into a budget
  # ---------------------------------------------------------------------------

  defp fit_blocks(_blocks, budget) when budget <= 0, do: {[], 0}

  defp fit_blocks(blocks, budget) do
    {parts, used} =
      Enum.reduce(blocks, {[], 0}, fn {content, _priority, _label}, {acc, tokens_used} ->
        block_tokens = estimate_tokens(content)
        available = budget - tokens_used

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

  defp extract_parts(blocks) do
    Enum.map(blocks, fn {content, _, _} -> content end)
  end

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
            Enum.reduce(calls, 0, fn tc, tc_acc ->
              name_tokens = estimate_tokens(safe_to_string(Map.get(tc, :name, "")))
              arg_tokens = estimate_tokens(safe_to_string(Map.get(tc, :arguments, "")))
              tc_acc + name_tokens + arg_tokens + 4
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

  defp memory_block_relevant(state) do
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

  defp recall_relevant(query) do
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
              overlap >= 2 or overlap >= MapSet.size(query_words) * 0.2
            end)

          case relevant do
            [] -> text
            _ -> Enum.join(relevant, "\n\n")
          end
        end
    end
  end

  defp full_recall do
    try do
      content = OptimalSystemAgent.Agent.Memory.recall()
      if content == "", do: nil, else: content
    rescue
      _ -> nil
    end
  end

  defp machines_block do
    addendums = OptimalSystemAgent.Machines.prompt_addendums()

    case addendums do
      [] -> nil
      list -> Enum.join(list, "\n\n")
    end
  rescue
    _ -> nil
  end

  defp os_templates_block do
    addendums = OptimalSystemAgent.OS.Registry.prompt_addendums()

    case addendums do
      [] -> nil
      list -> Enum.join(list, "\n\n")
    end
  rescue
    _ -> nil
  end

  defp workflow_block(state) do
    session_id = Map.get(state, :session_id)

    if session_id do
      Workflow.context_block(session_id)
    else
      nil
    end
  rescue
    _ -> nil
  end

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

  defp task_state_block(state) do
    session_id = Map.get(state, :session_id, "default")

    tasks =
      try do
        TaskTracker.get_tasks(session_id)
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

  defp cortex_block do
    case OptimalSystemAgent.Agent.Cortex.bulletin() do
      nil -> nil
      "" -> nil
      bulletin when is_binary(bulletin) -> "## Memory Bulletin\n#{bulletin}"
    end
  rescue
    _ -> nil
  end

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

  defp environment_block(_state) do
    cwd = File.cwd!()
    git_info = cached_git_info()
    elixir_ver = System.version()
    otp_release = :erlang.system_info(:otp_release) |> to_string()
    {os_family, os_name} = :os.type()
    date = Date.utc_today() |> Date.to_iso8601()
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    model = get_active_model(provider)

    """
    ## Environment
    - Working directory: #{cwd}
    - Date: #{date}
    - OS: #{os_family}/#{os_name}
    - Elixir #{elixir_ver} / OTP #{otp_release}
    - Provider: #{provider} / #{model}
    #{git_info}
    """
  rescue
    _ -> nil
  end

  defp cached_git_info do
    case Process.get(:osa_git_info_cache) do
      nil ->
        Logger.debug("[Context] git info cache miss — running git commands")
        info = gather_git_info()
        Process.put(:osa_git_info_cache, info)
        info

      cached ->
        Logger.debug("[Context] git info cache hit")
        cached
    end
  end

  defp gather_git_info do
    parts = []

    parts = case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
      {b, 0} -> ["- Git branch: #{String.trim(b)}" | parts]
      _ -> parts
    end

    parts = case System.cmd("git", ["status", "--short"], stderr_to_stdout: true) do
      {s, 0} when s != "" ->
        trimmed = String.trim(s)
        if trimmed != "", do: ["- Modified files:\n#{trimmed}" | parts], else: parts
      _ -> parts
    end

    parts = case System.cmd("git", ["log", "--oneline", "-5"], stderr_to_stdout: true) do
      {l, 0} -> ["- Recent commits:\n#{String.trim(l)}" | parts]
      _ -> parts
    end

    Enum.reverse(parts) |> Enum.join("\n")
  rescue
    _ -> ""
  end

  defp get_active_model(:anthropic), do: Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")
  defp get_active_model(:ollama), do: Application.get_env(:optimal_system_agent, :ollama_model, "detecting...")
  defp get_active_model(:openai), do: Application.get_env(:optimal_system_agent, :openai_model, "gpt-4o")
  defp get_active_model(provider) do
    key = :"#{provider}_model"
    Application.get_env(:optimal_system_agent, key, to_string(provider))
  end

  defp runtime_block(state) do
    """
    ## Runtime Context
    - Timestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    - Channel: #{state.channel}
    - Session: #{state.session_id}
    """
  end
end
