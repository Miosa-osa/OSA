defmodule OptimalSystemAgent.Agent.Loop.Guardrails do
  @moduledoc """
  Prompt injection detection and behavioral guardrails for the agent loop.

  Provides three-tier prompt injection detection (regex, normalized-unicode,
  structural) and behavioral heuristics (intent detection, code-in-text,
  verification gating, explore-first enforcement).
  """

  # Application-layer guardrail against system prompt extraction attempts.
  # Catches common injection patterns before the LLM processes them,
  # protecting weaker local models (Ollama) that may not follow system instructions.
  #
  # Three-tier detection (all deterministic, no LLM calls):
  #
  #   Tier 1 — Regex on raw trimmed input (fast first pass, < 1ms).
  #   Tier 2 — Regex on *normalized* input: zero-width chars stripped,
  #             fullwidth ASCII folded to ASCII, homoglyphs collapsed,
  #             then lowercased. Catches Unicode obfuscation tricks.
  #   Tier 3 — Structural analysis: detects prompt-boundary markers
  #             injected mid-message (SYSTEM:, ASSISTANT:, XML tags,
  #             markdown instruction headers).

  # Canonical refusal text returned for all prompt extraction attempts.
  # Used both on the input side (before the LLM sees the message) and on the
  # output side (if the LLM echoes system content despite the system prompt
  # instruction).  Centralised here so both guards are always in sync.
  @prompt_extraction_refusal "I can't share my internal configuration or system instructions."

  # Fingerprint phrases drawn from SYSTEM.md section headings and distinctive
  # content.  If the LLM response contains two or more of these, it has very
  # likely echoed the system prompt and the response must be replaced.
  # Each phrase is lowercased; matching is case-insensitive.
  @system_prompt_fingerprints [
    "signal theory",
    "optimal system agent",
    "tool usage policy",
    "explore before you act",
    "mandatory for coding tasks",
    "tool routing rules",
    "signal processing loop",
    "weight calibration",
    "doom loop detection",
    "mandatory verification",
    "tool definitions",
    "banned phrases",
    "code completeness",
    "orchestration",
    "existence denial"
  ]

  @doc "Returns the canonical refusal message for prompt extraction attempts."
  def prompt_extraction_refusal, do: @prompt_extraction_refusal

  @doc """
  Returns true when an LLM response appears to contain verbatim or near-verbatim
  content from the system prompt.

  Detection heuristic: if the lowercased response contains 2 or more of the
  distinctive fingerprint phrases that appear in SYSTEM.md, it is almost certain
  the model echoed the system prompt.  A single phrase can appear incidentally in
  normal conversation; two together indicate a leak.
  """
  def response_contains_prompt_leak?(response) when is_binary(response) do
    lowered = String.downcase(response)

    match_count =
      Enum.count(@system_prompt_fingerprints, fn phrase ->
        String.contains?(lowered, phrase)
      end)

    match_count >= 2
  end

  def response_contains_prompt_leak?(_), do: false

  @injection_patterns [
    ~r/what\s+(is|are|was)\s+(your\s+)?(system\s+prompt|instructions?|rules?|configuration|directives?)/i,
    ~r/what\s+(is|are|was)\s+the\s+(system\s+prompt|instructions?|configuration|directives?)/i,
    ~r/(show(\s+me)?|print|display|reveal|repeat|output|tell\s+me|give\s+me|say|recite|state|list|read)\s+(your\s+)?(system\s+prompt|instructions?|full\s+prompt|prompt|initial\s+prompt|configuration)/i,
    # "tell me your system prompt word for word" and inverted variants
    ~r/tell\s+me\s+.{0,30}(system\s+prompt|instructions?|rules?|prompt)\s*(word\s+for\s+word|verbatim|exactly|literally)?/i,
    ~r/(word\s+for\s+word|verbatim|character\s+for\s+character).{0,40}(prompt|instructions?|told|rules?)/i,
    # "ignore all instructions" without requiring previous/prior/above
    ~r/ignore\s+all\s+(instructions?|rules?|guidelines?|context|constraints?)/i,
    ~r/ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|prompt|context|rules?)/i,
    ~r/repeat\s+everything\s+(above|before|prior)/i,
    ~r/what\s+(were\s+)?(you\s+)?(told|instructed|programmed|trained|configured)\s+to/i,
    # DAN / jailbreak persona adoption
    ~r/(jailbreak|do\s+anything\s+now|developer\s+mode|prompt\s+injection)/i,
    ~r/\byou\s+(are|were|become|act\s+as)\s+DAN\b/i,
    ~r/\bDAN\s+(mode|protocol|activated|enabled)\b/i,
    # "pretend/act as if you have no restrictions"
    ~r/(pretend|act\s+as\s+if|imagine|behave\s+as\s+if)\s+.{0,40}(no\s+restrictions?|no\s+guidelines?|no\s+rules?|unrestricted|without\s+limits?|uncensored)/i,
    # "output everything above/before this"
    ~r/(output|print|repeat|copy|write\s+out)\s+(everything|all\s+text|all\s+content)\s+(above|before|prior)/i,
    ~r/disregard\s+(your\s+)?(previous\s+)?(instructions?|guidelines?|rules?)/i,
    ~r/forget\s+(everything|all)\s+(you\s+)?(were\s+)?(told|instructed|programmed)/i,
    ~r/system\s+prompt.*word\s+for\s+word/i,
    ~r/verbatim.*(prompt|instructions?)/i,
    ~r/(prompt|instructions?).*verbatim/i,
    ~r/copy\s+(and\s+)?(paste|output)\s+(your\s+)?(prompt|instructions?)/i,
    # "override/bypass/circumvent your instructions/restrictions"
    ~r/(override|bypass|circumvent|disable)\s+.{0,30}(instructions?|restrictions?|guidelines?|safety\s+filter)/i
  ]

  # Tier 3 — structural boundary markers that signal injected prompt sections.
  # Anchored to line-starts ((?:^|\n)) so they fire on injected headers,
  # not incidental mid-sentence occurrences.
  @structural_injection_patterns [
    # Role headers on their own line: SYSTEM:, ASSISTANT:, USER:
    ~r/(?:^|\n)\s*(?:system|assistant|user)\s*:/i,
    # Markdown instruction resets: ### New Instructions, ## Override, etc.
    ~r/(?:^|\n)\s*\#{1,6}\s*(?:new\s+instructions?|override|ignore\s+above|reset|updated?\s+rules?)/i,
    # XML-like prompt boundary tags: <system>, </instructions>, <prompt>, etc.
    ~r/<\/?\s*(?:system|instructions?|prompt|context|rules?)\s*>/i,
    # Bracket/chevron-delimited role tags: [SYSTEM], [INST], [/INST], <<SYS>>
    ~r/(?:\[|<<)\s*(?:SYSTEM|INST|SYS|ASSISTANT|USER)\s*(?:\]|>>)/,
    # Horizontal-rule followed by "instructions": ---\nNew instructions below
    ~r/(?:^|\n)-{3,}\s*\n\s*(?:new\s+)?instructions?/i
  ]

  @doc """
  Returns true if the message appears to be a prompt injection attempt.

  Three-tier detection: raw regex, unicode-normalized regex, structural analysis.
  """
  def prompt_injection?(message) when is_binary(message) do
    trimmed = String.trim(message)

    # Tier 1 — raw regex (fast path, < 1ms)
    if Enum.any?(@injection_patterns, &Regex.match?(&1, trimmed)) do
      true
    else
      # Tier 2 — regex on normalized input (catches Unicode obfuscation)
      normalized = normalize_for_injection_check(trimmed)

      tier2 =
        trimmed != normalized and
          Enum.any?(@injection_patterns, &Regex.match?(&1, normalized))

      if tier2 do
        true
      else
        # Tier 3 — structural boundary analysis
        Enum.any?(@structural_injection_patterns, &Regex.match?(&1, trimmed))
      end
    end
  end

  def prompt_injection?(_), do: false

  # Detect when a local model describes intent ("Let me check...") instead of
  # calling tools. Returns true if the response looks like narrated intent
  # rather than a final answer.
  @intent_patterns [
    ~r/\blet me (check|read|look|examine|create|write|edit|search|find|open|run|list|inspect)\b/i,
    ~r/\bi('ll| will) (check|read|look|create|write|edit|search|find|open|run|list|inspect)\b/i,
    ~r/\bi('m going to|am going to) /i,
    ~r/\bfirst,? i (need|want) to /i,
    ~r/\blet's start by /i,
    ~r/\bnow (i'll|let me|i will|i need to) /i,
    ~r/\bi (need|want) to (check|read|look|examine|create|write|edit|search|find|open|run|list)\b/i
  ]

  # Matches a code block with 5+ lines of actual code — indicates model wrote code
  # in its response text instead of calling file_write or file_edit.
  # Must have a language identifier (```python, ```typescript, etc.) to avoid
  # false positives on directory trees, command output, and plain text blocks.
  @code_block_pattern ~r/```(?:python|typescript|javascript|elixir|go|rust|java|ruby|bash|sh|sql|css|html|jsx|tsx|yaml|toml|json|c|cpp|swift|kotlin|scala|haskell|lua|perl|php|r|dart|zig|nim|svelte)\n(?:.*\n){5,}?```/

  @doc "Returns true if the content describes narrated intent rather than a final answer."
  def wants_to_continue?(nil), do: false
  def wants_to_continue?(content) when byte_size(content) < 20, do: false

  def wants_to_continue?(content) do
    Enum.any?(@intent_patterns, &Regex.match?(&1, content))
  end

  @doc "Returns true when model embeds a substantial code block instead of calling file_write/file_edit."
  def code_in_text?(nil), do: false
  def code_in_text?(content) when byte_size(content) < 50, do: false

  def code_in_text?(content) do
    Regex.match?(@code_block_pattern, content)
  end

  @doc """
  Verification gate — triggers when:
    1. iteration > 2 (agent has had multiple chances)
    2. Session has a task/goal context (user message contains action verbs)
    3. Zero tools were executed successfully in this session
  """
  def needs_verification_gate?(state) do
    state.iteration > 2 and
      has_task_context?(state.messages) and
      zero_successful_tools?(state.messages)
  end

  # Detect when a task involves code changes — triggers the explore-first directive.
  @coding_action_patterns ~r/\b(fix|change|update|refactor|add|implement|create|modify|edit|write|build|rewrite|delete|remove|rename)\b/i
  @coding_context_patterns ~r/\b(function|method|module|file|code|script|class|endpoint|handler|component|route|controller|service|model|schema|migration|test|spec|bug|error|feature)\b/i

  @doc "Returns true when the message describes a task involving code changes."
  def complex_coding_task?(message) when is_binary(message) do
    Regex.match?(@coding_action_patterns, message) and
      Regex.match?(@coding_context_patterns, message)
  end

  def complex_coding_task?(_), do: false

  @doc """
  Detect messages that need codebase exploration before action.

  Returns true when the user is asking about an unfamiliar codebase,
  requesting analysis of structure/architecture, or when the task
  is broad enough to warrant dispatching an explorer agent.
  """
  @exploration_patterns ~r/\b(explore|scan|what('s| is) in|show me the|project structure|codebase|architecture|how does .+ work|where is|find (all|the|every)|navigate|overview|map out|understand the|audit|analyze the|trace|call graph|dependency graph|what files)\b/iu

  def needs_exploration?(message) when is_binary(message) do
    Regex.match?(@exploration_patterns, message) and String.length(message) > 20
  end

  def needs_exploration?(_), do: false

  @doc """
  Detect messages that should use the delegate tool.

  Returns true when the message contains multi-part task indicators
  (numbered lists, role names like architect/backend/tester, or
  explicit delegation keywords). Used to inject a system directive
  that forces weaker models to call delegate instead of doing
  everything inline.
  """
  @delegation_role_pattern ~r/\b(architect|backend|frontend|tester|debugger|security.?auditor|code.?reviewer|researcher|devops|doc.?writer|refactorer|performance)\b/i
  @delegation_signal_pattern ~r/\b(delegate|subagent|sub.?agent|agent[s]?\s+(to|for)|use\s+(an?|the)\s+\w+\s+agent|team|assemble|dispatch)\b/i
  @list_with_roles_pattern ~r/-\s*(Architect|Backend|Frontend|Tester|Devops|Researcher)/i

  def delegation_task?(message) when is_binary(message) do
    has_roles = Regex.match?(@delegation_role_pattern, message)
    has_signal = Regex.match?(@delegation_signal_pattern, message)
    has_list_roles = Regex.match?(@list_with_roles_pattern, message)

    # Count independent deliverables — bullet points or numbered items
    bullet_count = count_task_bullets(message)

    # Smart detection:
    # 1. Explicit delegation signal ("delegate", "team", "agent")
    # 2. Role names in bullet list ("- Architect: ...")
    # 3. 4+ bullet points describing different deliverables (even without role names)
    # 4. Role names + 3+ bullets
    has_signal or has_list_roles or bullet_count >= 4 or (has_roles and bullet_count >= 3)
  end

  def delegation_task?(_), do: false

  # Count bullet points or numbered items that look like independent tasks.
  # Filters out sub-items (indented bullets) and short items (< 15 chars).
  defp count_task_bullets(message) do
    message
    |> String.split("\n")
    |> Enum.count(fn line ->
      trimmed = String.trim(line)

      is_bullet =
        Regex.match?(~r/^[-*•]\s+\S/, trimmed) or Regex.match?(~r/^\d+[\.\)]\s+\S/, trimmed)

      is_substantial = String.length(trimmed) >= 15
      not_indented = not Regex.match?(~r/^\s{2,}[-*•]/, line)
      is_bullet and is_substantial and not_indented
    end)
  end

  # Detect when the model issued write/execute tools without any read tools first.
  # Triggered at iteration 1 (first tool batch) to catch blind writes.
  @write_tools ~w(file_write file_edit shell_execute)
  @read_tools ~w(file_read dir_list file_glob file_grep mcts_index)

  @doc "Returns true when tool_calls contains write tools but no read tools."
  def write_without_read?(tool_calls) do
    names = Enum.map(tool_calls, & &1.name)
    has_write = Enum.any?(names, &(&1 in @write_tools))
    has_read = Enum.any?(names, &(&1 in @read_tools))
    has_write and not has_read
  end

  # --- Private helpers ---

  defp has_task_context?(messages) do
    messages
    |> Enum.any?(fn
      %{role: "user", content: content} when is_binary(content) ->
        Regex.match?(
          ~r/\b(fix|create|build|implement|add|update|change|write|deploy|test|debug|refactor|delete|remove|find|search|check|run|install|configure)\b/i,
          content
        )

      _ ->
        false
    end)
  end

  defp zero_successful_tools?(messages) do
    tool_messages =
      Enum.filter(messages, fn
        %{role: "tool", content: content} when is_binary(content) -> true
        _ -> false
      end)

    if tool_messages == [] do
      true
    else
      Enum.all?(tool_messages, fn %{content: content} ->
        String.starts_with?(content, "Error:") or
          String.starts_with?(content, "Blocked:")
      end)
    end
  end

  # Normalize user input before Tier 2 injection pattern matching.
  # Eliminates common Unicode obfuscation vectors without touching
  # the original string (Tier 1 always runs on raw input).
  #
  # Steps:
  #   1. Strip zero-width and invisible codepoints (U+200B, ZWNJ, BOM, etc.)
  #   2. Fold fullwidth ASCII (U+FF01–U+FF5E) to standard ASCII (U+0021–U+007E)
  #   3. Collapse common Cyrillic/Greek homoglyphs to ASCII equivalents
  #   4. Lowercase
  defp normalize_for_injection_check(input) when is_binary(input) do
    input
    # Step 1: strip zero-width / invisible codepoints
    |> String.replace(
      ~r/[\x{200B}\x{200C}\x{200D}\x{200E}\x{200F}\x{FEFF}\x{00AD}\x{2028}\x{2029}]/u,
      ""
    )
    # Step 2: fold fullwidth ASCII (！…～, U+FF01–U+FF5E) → standard ASCII (!…~)
    |> String.graphemes()
    |> Enum.map(fn g ->
      case String.to_charlist(g) do
        [cp] when cp >= 0xFF01 and cp <= 0xFF5E -> <<cp - 0xFF01 + 0x21::utf8>>
        _ -> g
      end
    end)
    |> Enum.join()
    # Step 3: collapse common Cyrillic/Greek homoglyphs to ASCII equivalents
    |> String.replace("а", "a")
    |> String.replace("е", "e")
    |> String.replace("о", "o")
    |> String.replace("р", "p")
    |> String.replace("с", "c")
    |> String.replace("х", "x")
    |> String.replace("у", "y")
    |> String.replace("і", "i")
    |> String.replace("ѕ", "s")
    |> String.replace("ν", "v")
    |> String.replace("ο", "o")
    |> String.replace("ρ", "p")
    # Step 4: lowercase
    |> String.downcase()
  end

  # --- Dead phrase stripping (output-side) ---
  #
  # The system prompt bans certain corporate filler phrases. Weaker models
  # (especially local ones like Nemotron) still produce them. Rather than
  # blocking the entire response, we strip or replace each dead phrase with
  # a natural alternative before it reaches the user.

  @dead_phrases [
    {"I apologize for the frustration", ""},
    {"I apologize for any inconvenience", ""},
    {"Thank you for your patience", ""},
    {"I will now proceed to", ""},
    {"I'd be happy to help", ""},
    {"Is there anything else", ""},
    {"I'm just a", "I'm a"},
    {"Certainly!", ""},
    {"Absolutely!", ""},
    {"As an AI", ""}
  ]

  # Compiled case-insensitive regex for each dead phrase, paired with its replacement.
  @dead_phrase_patterns Enum.map(@dead_phrases, fn {phrase, replacement} ->
                          {Regex.compile!("\\b" <> Regex.escape(phrase) <> "\\b", "i"),
                           replacement}
                        end)

  @doc """
  Returns true if the response contains any of the banned dead phrases
  from the system prompt.
  """
  def contains_dead_phrase?(response) when is_binary(response) do
    lowered = String.downcase(response)

    Enum.any?(@dead_phrases, fn {phrase, _} ->
      String.contains?(lowered, String.downcase(phrase))
    end)
  end

  def contains_dead_phrase?(_), do: false

  @doc """
  Strips dead phrases from a response, replacing each with its natural
  alternative (or removing it entirely). Cleans up leftover whitespace
  artifacts from removals.
  """
  def strip_dead_phrases(response) when is_binary(response) do
    result =
      Enum.reduce(@dead_phrase_patterns, response, fn {regex, replacement}, acc ->
        Regex.replace(regex, acc, replacement)
      end)

    # Clean up artifacts: double spaces, leading/trailing whitespace on lines,
    # and sentences that start with a lowercase comma fragment after removal.
    result
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.replace(~r/^\s+$/m, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  def strip_dead_phrases(response), do: response
end
