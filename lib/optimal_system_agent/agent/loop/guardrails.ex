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

  @doc """
  Returns true if the message appears to be a prompt injection attempt.

  Three-tier detection: raw regex, unicode-normalized regex, structural analysis.

  Backward-compatibility delegate: the canonical detector now lives in the
  Safety layer at `OptimalSystemAgent.Agent.Safety.PromptInjection` so that pure
  policy modules can depend on it without reaching up into the agent loop.
  """
  defdelegate prompt_injection?(message),
    to: OptimalSystemAgent.Agent.Safety.PromptInjection

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

  # ── Announcement-only completion ───────────────────────────────────────
  #
  # A turn whose LAST words announce the next action rather than report a result
  # did not finish; it stopped mid-sentence in the plan. `torch-pipeline-
  # parallelism` is the clean case: 29 turns, no truncation, no guard, no
  # background job, and a final answer of "I have enough understanding. Let me
  # write the implementation now." — after 14,000 characters of reasoning that
  # had worked the design out correctly. `/app/pipeline_parallel.py` was never
  # created. See `docs/research/failure-taxonomy.md` §7.
  #
  # This is deliberately NOT `wants_to_continue?/1`, which fires on any narrating
  # sentence anywhere in an answer of any length and is why `continue_on_text_only`
  # is off by default. The discriminator is the CONJUNCTION with brevity, and
  # both halves are load-bearing:
  #
  #   * announcement wording alone — an explanatory answer says "let me show
  #     you…" all the time;
  #   * `len < 500` alone — measured on the reference run, a bare length rule
  #     fires on solved trials at every threshold from 200 to 600 characters.
  #
  # Together they are `scripts/failure_species.py`'s `announced_next_action`,
  # which fires on 9 of 34 model failures and **0 of 49 solves** on that run.
  # The regex and the ceiling below are that detector's, verbatim, so the
  # measured precision is the same predicate and not a re-derivation of it.
  @announcement_pattern ~r/(let me |i'll (now|start|begin|write|investigate|wait|hold|report|keep|stop)|now let)/i
  @announcement_max_chars 500

  # "Let me know if …" is a sign-off, not an announcement: the work is done and
  # the model is offering follow-up. It matches `let me ` and so counts as an
  # announcement under the pattern above — a hole the reference run happens not
  # to exercise, because a solve that ends "Done. Let me know if you want the
  # benchmark numbers too." would have fired the shipped detector.
  #
  # Scrubbed BEFORE matching (length is still measured on the original), so the
  # phrase can no longer be the thing that makes an answer an announcement,
  # while "Let me write it now. Let me know if that's wrong." still fires on its
  # first clause. This can only SHRINK the fire set, so the measured
  # 0-of-49-solves carries over unchanged; replayed to confirm it also keeps all
  # 9 measured failures.
  @courtesy_pattern ~r/\blet me know\b/i

  @doc """
  Returns true when a text-only answer reads as an announcement of the next
  action rather than a report of a result.

  Keyed on wording AND brevity together; see the note above for why neither
  half works alone.
  """
  @spec announcement_only?(String.t() | nil) :: boolean()
  def announcement_only?(nil), do: false

  def announcement_only?(content) when is_binary(content) do
    String.length(content) < @announcement_max_chars and
      Regex.match?(@announcement_pattern, Regex.replace(@courtesy_pattern, content, ""))
  end

  def announcement_only?(_), do: false

  # ── The unstarted-task announcement ────────────────────────────────────
  #
  # The conjunct `not talked_only?/1` reads "a session that has only talked is a
  # conversation, not an interrupted task". That is right for a conversation and
  # wrong for the first turn of a task, and the second case is the worse one.
  #
  # Measured: `path-tracing` in
  # `bench/terminalbench/runs/VOID-contended-probe-minimal-04061c68` — one
  # generation, 263 output tokens, **zero tool calls**, $0.00174, and the whole
  # episode was
  #
  #     I'll start by examining the image to understand what I need to reproduce.
  #
  # then `[DONE]`. That run's binary already CONTAINED the announcement backstop
  # (21bdbc21 is an ancestor of 04061c68) and `announcement_only?/1` matches that
  # sentence — `i'll start`, 73 characters. The clause was blocked by
  # `not talked_only?/1` alone, because a session that has never called a tool
  # has, trivially, only talked.
  #
  # So the missing case is the exact opposite of a conversation: the model
  # announced the first action of a task and then did nothing at all. Three
  # further conjuncts keep it away from real conversation:
  #
  #   * `never_ran_a_tool?/1` — not "no tool SUCCEEDED" but "no tool result
  #     exists at all". The model did not try. This is also why the branch is
  #     structurally incapable of firing on a solved benchmark trial: a solve
  #     produced a deliverable, which needs at least one tool.
  #   * `deliverable_task?/1` on the user's own message — the request asks for
  #     something to be BUILT: a mutating verb (write / create / implement / …)
  #     plus either a code noun or a named artefact. This is what separates
  #     `path-tracing` ("Write a c program image.c …", "/app/image.ppm") from
  #     `TextOnlyTurnTerminationTest`'s fixture ("check how the retry budget is
  #     configured and explain it to me"), whose announcement-worded answer
  #     — "Let me check the configuration: the value lives in config/runtime.exs
  #     …" — is a complete answer and must still cost exactly one round trip.
  #     Note that "check" is deliberately NOT a mutating verb: a request to look
  #     something up is answerable in prose and needs no tool at all, which is
  #     exactly the over-firing that keeps `needs_verification_gate?/1` behind
  #     `continue_on_text_only`.
  #   * a tighter ceiling than the 500 the measured detector uses. At zero tools
  #     the announcement is the entire episode, so it is short; `path-tracing`'s
  #     was 73 characters. 500 is calibrated for an answer that reports work and
  #     then announces more; here there is no work to report.
  @unstarted_max_chars 200

  @doc """
  Should a text-only answer that announces the next action be continued, and why?

  Returns `{:continue, reason}` or `:stop`. Two admissible shapes, and the
  reason names which one fired so a continuation is legible in telemetry:

    * `:interrupted_task` — the session did real work and then announced the
      next step instead of taking it. The shipped, measured backstop
      (`announced_next_action`: 9 of 34 model failures, 0 of 49 solves on
      `bench/terminalbench/runs/osa-tb20-full89-f6981b61`).
      `torch-pipeline-parallelism` is this shape.
    * `:unstarted_task` — a coding task whose FIRST answer announces the first
      action, with no tool call anywhere in the session. `path-tracing` is this
      shape; see the note above for why it needs its own conjuncts.

  Everything else is `:stop`. A text-only answer that answers the user is a
  complete turn and must end.
  """
  @spec announcement_continue(String.t() | nil, [map()]) ::
          {:continue, :interrupted_task | :unstarted_task} | :stop
  def announcement_continue(content, messages) when is_binary(content) and is_list(messages) do
    cond do
      not announcement_only?(content) -> :stop
      not talked_only?(messages) -> {:continue, :interrupted_task}
      unstarted_task_announcement?(content, messages) -> {:continue, :unstarted_task}
      true -> :stop
    end
  end

  def announcement_continue(_content, _messages), do: :stop

  defp unstarted_task_announcement?(content, messages) do
    String.length(content) < @unstarted_max_chars and
      never_ran_a_tool?(messages) and
      Enum.any?(messages, fn
        %{role: "user", content: text} when is_binary(text) -> deliverable_task?(text)
        _ -> false
      end)
  end

  @doc """
  True when no tool result exists in `messages` at all — the model never even
  tried.

  Strictly stronger than `talked_only?/1`, which also returns true when every
  tool call errored. A session that tried and failed has started the task and
  is a different failure; this one has not started it.
  """
  @spec never_ran_a_tool?([map()]) :: boolean()
  def never_ran_a_tool?(messages) when is_list(messages) do
    not Enum.any?(messages, &match?(%{role: "tool"}, &1))
  end

  def never_ran_a_tool?(_), do: false

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

  # A named artefact: an absolute path, or a filename with a source/data
  # extension. `@coding_context_patterns` ("function", "module", "file", …)
  # covers a request phrased in the abstract; this covers one phrased
  # concretely. `path-tracing` needs this half — "Write a c program image.c
  # that I can run and compile" has the verb and the artefact but not one of
  # the nouns.
  @artefact_pattern ~r/(\/[\w.\-]+){2,}|\b[\w\-]+\.(c|h|cc|cpp|hpp|py|ex|exs|erl|rs|go|js|mjs|ts|tsx|jsx|java|rb|sh|bash|zsh|sql|json|ya?ml|toml|ini|cfg|md|txt|csv|tsv|ppm|png|jpe?g|cs|swift|kt|scala|lua|pl|php|r|zig|nim|ml|hs|dart|proto|lock|conf)\b/i

  @doc """
  True when the message asks for something to be BUILT — a mutating verb plus
  either a code noun or a concretely named artefact.

  Strictly narrower than `has_task_context?/1`, whose verb list also includes
  "check", "find" and "run": those describe requests that are answerable in
  prose, and treating them as tasks is what makes wording-based continuation
  chatter. Used by the `:unstarted_task` arm of `announcement_continue/2`.
  """
  @spec deliverable_task?(String.t() | term()) :: boolean()
  def deliverable_task?(message) when is_binary(message) do
    Regex.match?(@coding_action_patterns, message) and
      (Regex.match?(@coding_context_patterns, message) or
         Regex.match?(@artefact_pattern, message))
  end

  def deliverable_task?(_), do: false

  # ── Bug-report intent detection ─────────────────────────────────────────
  #
  # Recognises a turn as a *bug report* so the loop can inject a one-shot
  # systematic-debugging directive (see MessageHandler.build_pre_directives).
  # Precision is the point: ordinary feature work ("add a dark mode toggle",
  # "write a README") must NOT trip this. Four signals, any one is enough:
  #
  #   1. strong    — unambiguous failure words (broken, crash, traceback,
  #                  regression, panic, bug, fails/failing, "not working", …).
  #                  These almost never appear in a feature request.
  #   2. signature — a pasted stack trace / exception line (Python Traceback,
  #                  Elixir `** (FooError)`, `SomeError:`, node `at fn (file:line)`,
  #                  Python `File "x", line N`, Uncaught/Unhandled).
  #   3. problem-word — "error"/"exception" used as a *problem* ("getting an
  #                  error", "Error: …") but NOT as a feature noun ("error
  #                  handling", "exception message", "error boundary/page/…").
  #   4. fix-verb + problem-context — an explicit "fix"/"debug" paired with a
  #                  concrete problem noun ("fix the crash", "debug the timeout"),
  #                  so "fix the typo" / "fix the wording" stay out.
  @bug_strong_pattern ~r/\b(broke|broken|crash(?:es|ing|ed)?|traceback|stack\s?traces?|stacktraces?|regression|segfault|segmentation fault|panics?|bugs?|fails?|failing|failed|not\s+working|does\s?n'?t\s+work|do\s+not\s+work|is\s?n'?t\s+working|are\s?n'?t\s+working|wo\s?n'?t\s+work|will\s+not\s+work|stopped\s+working)\b/i

  @bug_signature_pattern ~r/Traceback \(most recent call last\)|Exception in thread|\*\* \([A-Z]\w*(?:Error|Exception)|(?<![\w.])[A-Z]\w*(?:Error|Exception)\b:|(?m:^\s*at\s+\S.*:\d+)|(?m:^\s*File ".*", line \d+)|\bUncaught\b|\bUnhandled\b/

  @bug_problem_word_pattern ~r/\b(errors?|exceptions?)\b/i
  @bug_feature_noun_pattern ~r/\b(error|exception)[ -]?(handling|handler|handlers|message|messages|boundary|boundaries|page|pages|logging|log|logs|state|states|code|codes|response|responses|toast|banner|notification|notifications|ui|component|components|display|screen|dialog|modal|type|types|class|classes|constant|constants|monitoring|reporting|tracking|middleware|wrapper)\b/i

  @bug_fix_verb_pattern ~r/\b(fix|fixes|fixing|debug|debugging|troubleshoot|diagnose)\b/i
  @bug_problem_context_pattern ~r/\b(bug|error|crash|issue|problem|broken|fail|failing|failure|wrong|unexpected|exception|regression|hang|hangs|hanging|freeze|frozen|stuck|null|nil|undefined|nan|500|404|502|timeout|leak|deadlock|race condition|infinite loop)\b/i

  @doc """
  Returns true when the user message reads as a bug report — a pasted error /
  stack trace, or phrasing like fix / broken / not working / crash / failing /
  regression / bug. Kept precise so normal feature requests do not trip it.
  """
  def bug_report?(message) when is_binary(message) do
    Regex.match?(@bug_strong_pattern, message) or
      Regex.match?(@bug_signature_pattern, message) or
      error_problem_signal?(message) or
      (Regex.match?(@bug_fix_verb_pattern, message) and
         Regex.match?(@bug_problem_context_pattern, message))
  end

  def bug_report?(_), do: false

  # "error"/"exception" used as a problem, not as a feature noun.
  defp error_problem_signal?(message) do
    Regex.match?(@bug_problem_word_pattern, message) and
      not Regex.match?(@bug_feature_noun_pattern, message)
  end

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
  Returns true when the user is asking for live visual context from the active
  screen or desktop.

  This is signal-based rather than tied to one exact sentence: it combines an
  observation verb with a visible-surface noun, or a direct reference to the
  shared UI.
  """
  def visual_observation_request?(message) when is_binary(message) do
    normalized = normalize_text(message)

    observation_signal?(normalized) and visible_surface_signal?(normalized)
  end

  def visual_observation_request?(_), do: false

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

  defp observation_signal?(message) do
    Regex.match?(~r/\b(see|seeing|look|watch|view|observe|inspect|read|show|tell)\b/u, message)
  end

  defp visible_surface_signal?(message) do
    Regex.match?(
      ~r/\b(screen|desktop|window|display|monitor|ui|interface|terminal|page|this|here)\b/u,
      message
    )
  end

  defp normalize_text(message) do
    message
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s']/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

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

  # Tools that actually mutate a file's bytes. `shell_execute` is deliberately
  # absent: it *can* mutate (`cat > f <<EOF`) but far more often it does not
  # (`ls`, `python3 test.py`, `git status`), and `@write_tools` cannot tell the
  # difference from the tool name alone. Treating it as a write is what made the
  # explore-first nudge tell the model it had "modified existing files" after a
  # read-only first command — measured on seven bench runs.
  #
  # `file_transform` is absent for a different reason: it is designed to need no
  # prior read (its `expect` counts are the guard), so a blind `file_transform`
  # is the intended usage, not a mistake. SYSTEM_LEAN §2.3 says so explicitly.
  @blind_write_tools ~w(file_write file_edit multi_file_edit)

  @doc """
  Returns true when this tool batch edits files it has not read.

  Narrower than `write_without_read?/1`: only actual file-mutating tools count
  as a write, so a first-turn shell probe is not mistaken for a blind edit.
  """
  @spec blind_file_write?([map()]) :: boolean()
  def blind_file_write?(tool_calls) do
    names = Enum.map(tool_calls, & &1.name)

    Enum.any?(names, &(&1 in @blind_write_tools)) and
      not Enum.any?(names, &(&1 in @read_tools))
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

  @doc """
  True when NO tool call in `messages` has succeeded — the session has only
  talked.

  Public because the announcement backstop needs the same question the
  zero-tool gate asks, from the opposite side: an answer that announces the next
  action only means "an interrupted task" if there was a task being executed.
  A conversation that never ran anything is a conversation, and narrating inside
  one ("Let me check the configuration: it lives in …") is ordinary prose.
  """
  @spec talked_only?([map()]) :: boolean()
  def talked_only?(messages) when is_list(messages), do: zero_successful_tools?(messages)
  def talked_only?(_), do: true

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
