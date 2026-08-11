defmodule OptimalSystemAgent.Agent.Safety.PromptInjection do
  @moduledoc """
  POLICY (pure): three-tier prompt-injection detection.

  This is the canonical detector for prompt-injection / system-prompt-extraction
  attempts. It lives in the Safety layer so that policy modules (the auto-mode
  `Classifier`) can depend on it without reaching up into the agent loop.

  Detection is deterministic (no LLM calls, no I/O) and layered:

    * Tier 1 — Regex on raw trimmed input (fast first pass, < 1ms).
    * Tier 2 — Regex on *normalized* input: zero-width chars stripped,
      fullwidth ASCII folded to ASCII, homoglyphs collapsed, then lowercased.
      Catches Unicode obfuscation tricks.
    * Tier 3 — Structural analysis: detects prompt-boundary markers injected
      mid-message (SYSTEM:, ASSISTANT:, XML tags, markdown instruction headers).

  `OptimalSystemAgent.Agent.Loop.Guardrails.prompt_injection?/1` delegates here
  for backward compatibility.
  """

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

  # Patterns that are meaningful when they appear in *untrusted third-party
  # text* (fetched web pages, MCP tool output, transcript turns being fed to a
  # policy classifier) rather than in a message the user typed.
  #
  # These are deliberately NOT part of `@injection_patterns`. The user-message
  # classifier is tuned for "the human is trying to extract my system prompt",
  # and its verdict is used to REFUSE the turn. Neither the tuning nor the
  # consequence transfers: a web page saying "ignore previous instructions" is
  # not the user misbehaving, and refusing the user's turn is the wrong
  # response. Untrusted text is delimited and defanged, never refused — see
  # `OptimalSystemAgent.Agent.Safety.UntrustedContent`.
  @untrusted_directive_patterns [
    # Direct instruction to the reading model.
    ~r/ignore\s+(all\s+)?(the\s+)?(previous|prior|above|preceding|earlier)\s+(instructions?|prompts?|rules?|context|directions?)/i,
    ~r/disregard\s+(all\s+)?(the\s+)?(previous|prior|above|preceding|earlier|system)\s+(instructions?|prompts?|rules?|context)/i,
    ~r/forget\s+(everything|all)\s+(you\s+)?(were\s+)?(told|instructed|read)/i,
    # Impersonating operator/system authority.
    ~r/\b(new|updated?|revised|override|overriding)\s+(system\s+)?(instructions?|rules?|directives?|policy)\b/i,
    ~r/\b(important|urgent|attention)\s*:?\s*(ai|assistant|agent|model|llm|claude|gpt)\b/i,
    ~r/\bthis\s+(is|message\s+is)\s+(a\s+)?(system|admin|operator|developer)\s+(message|instruction|override)/i,
    # Steering the agent's tool use / permissions.
    ~r/\byou\s+(must|should|are\s+required\s+to|need\s+to)\s+(now\s+)?(run|execute|call|invoke)\b/i,
    ~r/\b(auto[-\s]?approve|approve\s+automatically|without\s+asking|do\s+not\s+ask|don'?t\s+ask)\s+(the\s+)?(user|permission|for\s+approval)?/i,
    ~r/\b(this|the)\s+(command|action|tool\s+call)\s+is\s+(safe|harmless|already\s+approved|pre[-\s]?approved)\b/i,
    # Credential / exfiltration solicitation.
    ~r/\b(send|post|upload|exfiltrate|transmit)\s+.{0,40}(to\s+https?:\/\/|to\s+the\s+following\s+url)/i,
    ~r/\b(reveal|print|output|show)\s+.{0,30}(api\s*key|token|credential|secret|password|\.env)/i
  ]

  @doc """
  Structural prompt-boundary markers only (Tier 3), exposed on its own.

  Used by untrusted-content handling, which must know whether a *third party's*
  text is trying to forge prompt structure, independent of the user-message
  verdict.
  """
  @spec structural_injection?(term()) :: boolean()
  def structural_injection?(text) when is_binary(text) do
    Enum.any?(@structural_injection_patterns, &Regex.match?(&1, text))
  end

  def structural_injection?(_), do: false

  @doc """
  Screen text that arrived from an untrusted third party (a fetched page, an
  MCP server's output, a transcript turn under attacker influence).

  Returns `{:suspicious, markers}` when the text forges prompt structure or
  addresses the reading model as if it were the operator, else `:clean`.
  `markers` is a small list of `:structural` / `:directive` atoms plus the
  matched excerpt, for logging and for annotating the delimited block.

  This is intentionally a DIFFERENT question from `prompt_injection?/1`:
  that one asks "is the user attacking me" and its answer refuses the turn.
  This one asks "is this data pretending to be instructions" and its answer
  only labels the data.
  """
  @spec screen_untrusted(term()) :: :clean | {:suspicious, [{atom(), String.t()}]}
  def screen_untrusted(text) when is_binary(text) do
    normalized = normalize_for_injection_check(text)

    structural =
      for p <- @structural_injection_patterns,
          m = first_match(p, text) || first_match(p, normalized),
          do: {:structural, m}

    directive =
      for p <- @untrusted_directive_patterns,
          m = first_match(p, text) || first_match(p, normalized),
          do: {:directive, m}

    case Enum.take(structural ++ directive, 8) do
      [] -> :clean
      markers -> {:suspicious, markers}
    end
  end

  def screen_untrusted(_), do: :clean

  defp first_match(pattern, text) do
    case Regex.run(pattern, text) do
      [m | _] -> m |> String.trim() |> String.slice(0, 80)
      _ -> nil
    end
  end

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
end
