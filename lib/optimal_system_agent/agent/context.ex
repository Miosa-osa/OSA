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
  natively — same pattern as Claude Code, Cursor, Windsurf.

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

  alias OptimalSystemAgent.Agent.Workflow
  alias OptimalSystemAgent.Agent.TaskTracker
  alias OptimalSystemAgent.Soul

  @response_reserve 4_096

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

    max_tok = max_tokens()

    # Tier 1: Cached static base
    static_base = Soul.static_base()
    static_tokens = Soul.static_token_count()

    # Tier 2: Dynamic context
    dynamic_budget = max(max_tok - @response_reserve - conversation_tokens - static_tokens, 1_000)
    dynamic_context = assemble_dynamic_context(state, dynamic_budget)

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
    dynamic_context = assemble_dynamic_context(state, dynamic_budget)
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

  defp assemble_dynamic_context(state, budget) do
    blocks = gather_dynamic_blocks(state)

    # All blocks are tier 1 (always included) — just fit within budget
    {parts, _used} = fit_blocks(blocks, budget)

    parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  # ---------------------------------------------------------------------------
  # Dynamic block gathering — each returns {content, priority, label}
  # ---------------------------------------------------------------------------

  defp gather_dynamic_blocks(state) do
    [
      {tool_process_block(), 1, "tool_process"},
      {runtime_block(state), 1, "runtime"},
      {environment_block(state), 1, "environment"},
      {plan_mode_block(state), 1, "plan_mode"},
      {memory_block_relevant(state), 1, "memory"},
      {task_state_block(state), 1, "task_state"},
      {workflow_block(state), 1, "workflow"},
      {skills_block(state), 2, "skills"}
    ]
    |> Enum.reject(fn {content, _, _} -> is_nil(content) or content == "" end)
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

    ### Tool Routing Rules (CRITICAL)

    - Use **file_read** — NOT shell_execute with cat/head/tail
    - Use **file_edit** for surgical changes — NOT shell_execute with sed/awk. NEVER file_write for small edits.
    - Use **mcts_index** — for finding relevant files in a large/unfamiliar codebase. Faster and smarter than file_glob loops.
    - Use **file_glob** — for specific pattern-based file search when you know what you're looking for.
    - Use **file_grep** — NOT shell_execute with grep/rg for content search
    - Use **dir_list** — NOT shell_execute with ls for directory listing
    - Use **web_fetch** — NOT shell_execute with curl for fetching URLs
    - Reserve **shell_execute** for system commands only (git, mix, npm, docker, make, etc.)

    ### When to Use Each Tool

    - **file_read** — Read file content. Always read before modifying.
    - **file_write** — Create new files or completely rewrite existing ones. Read first if file exists.
    - **file_edit** — Surgical string replacement in existing files. old_string must be unique. Preferred over file_write for modifications.
    - **file_glob** — Find files by pattern (e.g. '**/*.ex', 'lib/**/*.ts').
    - **file_grep** — Search file contents by regex. Returns file:line:content matches.
    - **dir_list** — List directory contents with types and sizes.
    - **shell_execute** — Run system commands: git, mix test, npm, docker, compile, etc.
    - **web_search** — Search the web for current information or documentation.
    - **web_fetch** — Fetch and read a specific URL's content.
    - **memory_save** — Save important information to persistent memory.
    - **orchestrate** — Spawn parallel sub-agents for complex multi-part tasks.
    - **mcts_index** — MCTS-powered codebase indexer. Use when you need to find relevant files in a large codebase efficiently. Ranks files by relevance to your goal using Monte Carlo Tree Search.

    ### When NOT to Use Tools

    - Greetings and casual conversation ("hey", "thanks", "what's up")
    - Questions you can answer from your training knowledge
    - Opinions or recommendations that don't require looking at files

    ### Important Rules

    - **Always read before writing.** Never modify a file you haven't read first.
    - **Use file_edit for surgical changes.** Only use file_write for new files or complete rewrites.
    - **One tool call per turn.** Call one tool, get the result, then decide the next step.
    - **Use absolute paths.** The current working directory is: #{cwd}
    - **Be proactive.** If the user asks to "fix" something, read → find → fix → verify.

    ### Brevity

    - Answer concisely. Fewer than 4 lines unless detail is requested.
    - No preamble. No postamble. Direct answers.
    - Don't add features, refactor, or improve beyond what was asked.

    ### Code Safety

    - ALWAYS read a file before editing it.
    - Use file_edit for surgical changes. Only use file_write for new files or complete rewrites.
    - Don't add error handling for impossible scenarios.
    - Don't create abstractions for one-time operations.
    """
  end

  defp environment_block(_state) do
    cwd = File.cwd!()
    git_info = cached_git_info()
    elixir_ver = System.version()
    otp_release = :erlang.system_info(:otp_release) |> to_string()
    {os_family, os_name} = :os.type()
    date = Date.utc_today() |> Date.to_iso8601()
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    model = get_active_model(provider)
    workspace = Path.expand("~/.osa/workspace")
    workspace_info = cached_workspace_overview(workspace)

    """
    ## Environment
    - Working directory: #{cwd}
    - User workspace: #{workspace} (write all user projects and code here)
    #{workspace_info}- Date: #{date}
    - OS: #{os_family}/#{os_name}
    - Elixir #{elixir_ver} / OTP #{otp_release}
    - Provider: #{provider} / #{model}
    #{git_info}
    """
  rescue
    _ -> nil
  end

  defp cached_workspace_overview(workspace) do
    case Process.get(:osa_workspace_overview_cache) do
      nil ->
        overview = build_workspace_overview(workspace)
        Process.put(:osa_workspace_overview_cache, overview)
        overview

      cached ->
        cached
    end
  end

  defp build_workspace_overview(workspace) do
    unless File.dir?(workspace), do: "", else: do_build_workspace_overview(workspace)
  rescue
    _ -> ""
  end

  defp do_build_workspace_overview(workspace) do
    project_type = detect_project_type(workspace)
    file_count = count_workspace_files(workspace)
    tree = compact_workspace_tree(workspace)

    tree_line = if tree != "", do: "- Structure:\n#{tree}\n", else: ""

    "- Workspace project: #{project_type} (#{file_count} files)\n#{tree_line}"
  end

  defp detect_project_type(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> "Elixir/OTP"
      File.exists?(Path.join(dir, "go.mod")) -> "Go"
      File.exists?(Path.join(dir, "Cargo.toml")) -> "Rust"
      File.exists?(Path.join(dir, "package.json")) -> "Node.js"
      File.exists?(Path.join(dir, "pyproject.toml")) or
          File.exists?(Path.join(dir, "requirements.txt")) -> "Python"
      File.exists?(Path.join(dir, "pom.xml")) -> "Java"
      true -> "Generic"
    end
  end

  defp count_workspace_files(dir) do
    case System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output |> String.split("\n") |> Enum.reject(&(&1 == "")) |> length()

      _ ->
        Path.wildcard(Path.join(dir, "**/*")) |> Enum.count(&File.regular?/1)
    end
  rescue
    _ -> 0
  end

  @workspace_skip ~w(node_modules _build deps .git __pycache__ dist build target .elixir_ls ebin)

  defp compact_workspace_tree(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(fn e -> e in @workspace_skip or String.starts_with?(e, ".") end)
        |> Enum.sort()
        |> Enum.take(12)
        |> Enum.map(fn entry ->
          path = Path.join(dir, entry)

          if File.dir?(path) do
            count = count_dir_summary(path)
            "    #{entry}/ (#{count})"
          else
            "    #{entry}"
          end
        end)
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp count_dir_summary(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        files = Enum.count(entries, &File.regular?(Path.join(dir, &1)))
        dirs = Enum.count(entries, fn e ->
          File.dir?(Path.join(dir, e)) and e not in @workspace_skip
        end)

        cond do
          files > 0 and dirs > 0 -> "#{files} files, #{dirs} dirs"
          files > 0 -> "#{files} files"
          dirs > 0 -> "#{dirs} dirs"
          true -> "empty"
        end

      _ ->
        "?"
    end
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

  defp skills_block(_state) do
    try do
      OptimalSystemAgent.Tools.Registry.active_skills_context()
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end
end
