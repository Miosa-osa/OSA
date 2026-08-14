defmodule OptimalSystemAgent.Agent.Loop.MessageHandler do
  @moduledoc """
  Pre-LLM message processing for the agent loop.

  Handles the preprocessing phase of `handle_call({:process, ...})`:
  - Memory nudge injection (every N turns)
  - Pre-directive injection (explore-first, delegation enforcement)
  - Plan mode execution — the INVESTIGATIVE agent loop (read-only tools ON,
    mutating tools blocked at the permission layer), not a single no-tools
    LLM call. See `run_plan_mode/1`.

  These concerns were extracted from the main loop to keep `Loop` focused on
  GenServer callbacks and the ReAct iteration, not message decoration.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Reminders
  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Events.Bus

  @doc """
  Build the final message list to append for this turn.

  Injects a memory nudge every `auto_insights_interval` turns, then prepends
  any system directives required by the message content (explore-first,
  delegation enforcement).

  Returns a list of message maps ready to append to `state.messages`.
  """
  @spec build_messages(String.t(), map()) :: list(map())
  def build_messages(message, state), do: build_messages(message, state, [])

  @doc """
  Same as `build_messages/2`, but when `images` is a non-empty list the user
  turn is emitted as structured content blocks (`text` + one `image` block per
  entry) so vision-capable providers actually receive the image bytes.

  An entry is either inline image bytes (a `data:image/...;base64,...` URL or a
  bare base64 blob — a clipboard paste) or a filesystem path. Ingestion is NOT
  "read whatever string arrived":

    * A path is canonicalised through `Agent.Safety.PathCanon` (real recursive
      realpath, so an intermediate directory symlink cannot smuggle the target
      elsewhere) and then run through `Agent.Safety.PathPolicy.check_read_as/3`
      with this turn's `source`. Without a policy check at all, an `images`
      entry is an arbitrary-file-read primitive that base64s the result
      straight into an outbound provider request: `images: ["~/.ssh/id_rsa"]`
      or `["../.env"]` exfiltrates the file.

      `source` is the trust marker, and it decides ONE rule — allowed-roots
      confinement:

        - `:model` (the default, and what an unmarked `POST
          /api/v1/orchestrate` body gets) — the path was chosen by the model or
          by an unidentified caller. Full `check_read/2` confinement: outside
          `read_roots/0` is refused.
        - `:user` — the path came from an explicit user action the TUI
          performed: a drag-and-drop, a clipboard paste, an `@file` mention.
          `check_user_attachment/2`: readable from anywhere on the filesystem,
          because a screenshot lives in `$TMPDIR` or on the Desktop and never
          inside the workspace. v1.0.79 lacked this distinction and refused the
          owner's own screenshots.

      Everything that is not about location applies to BOTH: canonicalisation,
      the sensitive-file blocklist (a mis-dragged private key is still
      refused), the byte cap, the magic-byte sniff, and "no such file".
    * The media type is sniffed from MAGIC BYTES, never guessed from the
      extension. The old code defaulted an unknown extension to `image/png`,
      which both mislabels real images and lets a non-image file through.
    * A byte cap applies (`:max_image_bytes`, default 10 MB).
    * A path that does not exist is an ERROR. It used to fall through to "treat
      the string as base64 image bytes", so a typo'd path was shipped to the
      provider as a garbage payload and the user got a confused model answer
      instead of "that file does not exist".

  Rejected entries are reported to the model in a `system` directive placed
  immediately before the user turn, so a dropped attachment is visible rather
  than silent.
  """
  @spec build_messages(String.t(), map(), list(), :user | :model) :: list(map())
  def build_messages(message, state, images, source \\ :model) when is_list(images) do
    message_with_nudge = maybe_inject_memory_nudge(message, state)
    pre_directives = build_pre_directives(message_with_nudge, state)

    {image_blocks, errors} = ingest_images(images, source)

    user_msg =
      case image_blocks do
        [] -> %{role: "user", content: message_with_nudge}
        blocks -> %{role: "user", content: [%{type: "text", text: message_with_nudge} | blocks]}
      end

    pre_directives ++ rejection_directives(errors) ++ [user_msg]
  end

  # ── Image ingestion ───────────────────────────────────────────────────────

  # Anthropic (and every other vision API OSA talks to) accepts exactly these
  # four. Anything else is refused rather than mislabelled as PNG.
  @image_types ["image/png", "image/jpeg", "image/gif", "image/webp"]

  @default_max_image_bytes 10 * 1024 * 1024

  # Cheap shape guard before attempting a base64 decode, so a filesystem path
  # is never mistaken for a payload: base64's alphabet excludes `.`, `-`, `~`
  # and `/`-adjacent path punctuation is not enough on its own to decode.
  @base64_re ~r/\A[A-Za-z0-9+\/\s]+={0,2}\z/

  @doc false
  @spec ingest_images(list(), :user | :model) :: {list(map()), list(String.t())}
  def ingest_images(images, source \\ :model) when is_list(images) do
    source = normalize_source(source)

    {blocks, errors} =
      Enum.reduce(images, {[], []}, fn entry, {blocks, errors} ->
        case image_entry_to_block(entry, source) do
          {:ok, block} -> {[block | blocks], errors}
          {:error, reason} -> {blocks, [reason | errors]}
        end
      end)

    {Enum.reverse(blocks), Enum.reverse(errors)}
  end

  defp rejection_directives([]), do: []

  defp rejection_directives(errors) do
    lines = Enum.map_join(errors, "\n", &("  - " <> &1))

    [
      %{
        role: "system",
        content:
          "[System: #{length(errors)} image attachment(s) could NOT be attached and are not " <>
            "part of this turn. Do not describe or reason about them; tell the user what " <>
            "failed.\n" <> lines <> "]"
      }
    ]
  end

  # Anything that is not exactly `:user` is untrusted. Fail-closed on typos and
  # on values that crossed a wire (`"user"` is accepted, everything else is
  # `:model`) so a missing/garbled marker can never widen the policy.
  @doc false
  @spec normalize_source(term()) :: :user | :model
  def normalize_source(:user), do: :user
  def normalize_source("user"), do: :user
  def normalize_source(_), do: :model

  defp image_entry_to_block(entry, source) when is_binary(entry) and entry != "" do
    case classify_entry(entry) do
      {:inline, bytes} -> block_from_bytes(bytes, "pasted image data")
      {:path, path} -> block_from_path(path, source)
    end
  end

  defp image_entry_to_block(other, _source),
    do: {:error, "unsupported image attachment: #{inspect(other)}"}

  # A `data:` URL or a bare base64 blob is inline bytes; everything else is a
  # path. Decoding is only attempted when the string cannot be a path shape,
  # so a real path is never swallowed as a payload (and vice versa).
  defp classify_entry("data:" <> _ = entry) do
    case Regex.run(~r{\Adata:[^;,]*;base64,(.*)\z}s, entry) do
      [_, payload] ->
        case Base.decode64(payload, ignore: :whitespace) do
          {:ok, bytes} -> {:inline, bytes}
          :error -> {:inline, <<>>}
        end

      _ ->
        {:inline, <<>>}
    end
  end

  defp classify_entry(entry) do
    if byte_size(entry) >= 24 and Regex.match?(@base64_re, entry) do
      case Base.decode64(entry, ignore: :whitespace) do
        {:ok, bytes} -> {:inline, bytes}
        :error -> {:path, entry}
      end
    else
      {:path, entry}
    end
  end

  defp block_from_path(entry, source) do
    canonical = PathPolicy.canonical(entry)

    with :ok <- policy_check(entry, source),
         :ok <- exists_check(canonical, entry),
         {:ok, size} <- regular_file_size(canonical, entry),
         :ok <- size_check(size, entry),
         {:ok, bytes} <- read_file(canonical, entry) do
      block_from_bytes(bytes, entry)
    end
  end

  defp policy_check(entry, source) do
    case PathPolicy.check_read_as(source, entry, entry) do
      :ok -> :ok
      {:deny, reason} -> {:error, reason}
    end
  end

  defp exists_check(canonical, entry) do
    if File.exists?(canonical), do: :ok, else: {:error, "#{entry}: no such file"}
  end

  defp regular_file_size(canonical, entry) do
    case File.stat(canonical) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{type: type}} -> {:error, "#{entry}: not a regular file (#{type})"}
      {:error, posix} -> {:error, "#{entry}: cannot stat (#{:file.format_error(posix)})"}
    end
  end

  defp size_check(size, entry) do
    max = max_image_bytes()

    if size > max do
      {:error, "#{entry}: #{size} bytes exceeds the #{max}-byte image attachment limit"}
    else
      :ok
    end
  end

  defp read_file(canonical, entry) do
    case File.read(canonical) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, posix} -> {:error, "#{entry}: cannot read (#{:file.format_error(posix)})"}
    end
  end

  defp block_from_bytes(bytes, label) do
    cond do
      byte_size(bytes) == 0 ->
        {:error, "#{label}: empty image data"}

      byte_size(bytes) > max_image_bytes() ->
        {:error,
         "#{label}: #{byte_size(bytes)} bytes exceeds the #{max_image_bytes()}-byte " <>
           "image attachment limit"}

      true ->
        case sniff_media_type(bytes) do
          {:ok, media_type} when media_type in @image_types ->
            {:ok,
             %{
               type: "image",
               source: %{type: "base64", media_type: media_type, data: Base.encode64(bytes)}
             }}

          _ ->
            {:error, "#{label}: not a supported image (expected PNG, JPEG, GIF or WebP)"}
        end
    end
  end

  # Content sniffing, not extension trust. The extension is attacker-chosen and
  # the old `media_type_for/1` defaulted anything unknown to "image/png".
  defp sniff_media_type(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: {:ok, "image/png"}
  defp sniff_media_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp sniff_media_type(<<"GIF87a", _::binary>>), do: {:ok, "image/gif"}
  defp sniff_media_type(<<"GIF89a", _::binary>>), do: {:ok, "image/gif"}
  defp sniff_media_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp sniff_media_type(_), do: :error

  defp max_image_bytes do
    Application.get_env(:optimal_system_agent, :max_image_bytes, @default_max_image_bytes)
  end

  @doc """
  Execute the plan mode branch: the INVESTIGATIVE agent loop.

  Runs the real `ReactLoop` (multi-step, streaming, same as a normal turn) but
  temporarily forces `permission_mode: :plan` so the tool-execution gate
  (`ToolExecutor.approve_tool_call/2`) allows read-only tools (file_read,
  file_grep, file_glob, dir_list, codebase_explore, web_fetch, ...) while
  blocking anything mutating. `Context.plan_mode_block/1` instructs the model
  to investigate first and only then produce its final plain-text answer —
  that final answer (no further tool call) is the plan text, exactly as the
  old single-call plan mode returned, so downstream consumers (`PlanStore`,
  the TUI's `plan_review` dialog, `plan_proposed` event) are unchanged.

  This replaces the old "single LLM call with no tools" implementation (OSA
  used to plan blind); see `docs/decisions/` / the plan-mode audit for why
  ungrounded plans are a failure mode CC's ExitPlanMode prompt warns against.

  Returns `{:ok, plan_text, state}` on success or `{:error, reason, state}` on
  failure. In both cases `plan_mode` is cleared and `permission_mode` is
  restored to whatever it was before entering plan mode.
  """
  @spec run_plan_mode(map()) ::
          {:ok, String.t(), map()}
          | {:error, term(), map()}
  def run_plan_mode(state) do
    original_permission_mode = Map.get(state, :permission_mode, :ask)
    investigative_state = %{state | permission_mode: :plan}

    {response, ran_state} =
      try do
        ReactLoop.run(investigative_state)
      rescue
        e ->
          Logger.error(
            "[plan_mode] CRASH in investigative ReactLoop: #{Exception.message(e)}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          {nil, investigative_state}
      catch
        :exit, reason ->
          Logger.error("[plan_mode] EXIT in investigative ReactLoop: #{inspect(reason)}")
          {nil, investigative_state}
      end

    cond do
      # A cancelled/paused turn returns one of ReactLoop's typed interrupt
      # markers instead of real plan prose — never stash that as a plan.
      is_binary(response) and response in ReactLoop.interrupt_markers() ->
        state = %{ran_state | plan_mode: false, permission_mode: original_permission_mode}
        {:error, :interrupted, state}

      is_binary(response) and response != "" ->
        plan_text = response
        state = %{ran_state | plan_mode: false, permission_mode: original_permission_mode}

        Bus.emit(:agent_response, %{
          session_id: state.session_id,
          response: plan_text,
          response_type: "plan",
          agent: state.session_id
        })

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:session:#{state.session_id}",
          {:osa_event,
           %{
             type: :agent_response,
             session_id: state.session_id,
             message_id: LLMClient.current_message_id(),
             response: plan_text,
             response_type: "plan"
           }}
        )

        # Stash the plan + original user input so the plan_approve / plan_edit
        # commands can resume execution without the client echoing the plan
        # back, then emit the dedicated `plan_proposed` event the TUI parses to
        # open its plan_review dialog (a plain agent_response does not). Also
        # writes the durable plan file (source of truth — see `PlanStore`).
        original_input = original_user_input(state.messages)
        OptimalSystemAgent.Agent.PlanStore.put(state.session_id, plan_text, original_input)

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:session:#{state.session_id}",
          {:osa_event,
           %{
             type: :system_event,
             event: :plan_proposed,
             session_id: state.session_id,
             plan: plan_text
           }}
        )

        {:ok, plan_text, state}

      true ->
        Logger.warning(
          "Plan mode investigative loop produced no response, falling back to normal execution"
        )

        state = %{ran_state | plan_mode: false, permission_mode: original_permission_mode}
        {:error, :empty_plan_response, state}
    end
  end

  # --- Private ---

  # Recover the original user message from the decorated message list so the
  # plan_approve / plan_edit round-trip can reference it. build_messages/2
  # appends system pre-directives followed by the user message, so the last
  # role == "user" entry is the genuine input.
  defp original_user_input(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} when is_binary(content) -> content
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      _ -> false
    end)
  end

  defp original_user_input(_), do: ""

  defp maybe_inject_memory_nudge(message, state) do
    interval = Application.get_env(:optimal_system_agent, :auto_insights_interval, 10)

    if rem(state.turn_count, interval) == 0 and state.turn_count > 0 do
      message <>
        "\n\n[System: You've had #{state.turn_count} exchanges. " <>
        "Consider saving important context with memory_save if you haven't recently.]"
    else
      message
    end
  end

  defp build_pre_directives(message, state) do
    []
    |> maybe_add_task_directive(message)
    |> maybe_add_visual_observation_directive(message)
    |> maybe_add_debugging_directive(message, state)
    |> maybe_add_explore_directive(message)
    |> maybe_add_delegation_directive(message, state)
    |> maybe_add_progress_ledger_directive(state)
    |> Enum.reverse()
  end

  # The cross-tier memory recall block used to be injected here, as a
  # `role: "system"` message appended permanently to `state.messages` once per
  # user turn. MEASURED over 15 turns: 14 near-identical copies in one request,
  # 2,717 redundant tokens, growing ~220/turn forever.
  #
  # It now lives in `Agent.Context.memory_recall_block/1` as a dynamic block, so
  # it is rebuilt (not accumulated) each turn, budgeted with the other recall
  # blocks, and placed in the volatile system tail where `Providers.PromptCache`
  # moves it outside the cached prefix. See that function for why deleting the
  # previous copy in place — the obvious fix — would have broken prefix
  # stability and cost more than it saved.

  # Prepend a compact recap of the progress ledger so coherence survives
  # context resets/compaction. summarize/1 returns {:error, :not_found} until
  # the first progress_note is recorded, so early turns inject nothing.
  defp maybe_add_progress_ledger_directive(acc, %{session_id: sid}) when is_binary(sid) do
    case OptimalSystemAgent.Agent.ProgressLedger.summarize(sid) do
      {:ok, summary} ->
        [%{role: "system", content: "[System: Progress ledger recap]\n" <> summary} | acc]

      _ ->
        acc
    end
  end

  defp maybe_add_progress_ledger_directive(acc, _), do: acc

  # Detect multi-step tasks and nudge to create a task list
  defp maybe_add_task_directive(acc, message) do
    bullet_count = count_task_indicators(message)

    if bullet_count >= 3 or Guardrails.complex_coding_task?(message) do
      directive = %{
        role: "system",
        content:
          "[System: This task has multiple steps. Create a task list with task_write BEFORE " <>
            "starting work. Create one task per step, then mark each in_progress as you start " <>
            "and completed as you finish. The user sees your progress in real-time.]"
      }

      [directive | acc]
    else
      acc
    end
  end

  defp count_task_indicators(message) do
    message
    |> String.split("\n")
    |> Enum.count(fn line ->
      trimmed = String.trim(line)

      Regex.match?(~r/^[-*•]\s+\S/, trimmed) or
        Regex.match?(~r/^\d+[\.\)]\s+\S/, trimmed)
    end)
  end

  defp maybe_add_explore_directive(acc, message) do
    cond do
      # Large/unfamiliar codebase exploration — dispatch explorer agent
      Guardrails.needs_exploration?(message) ->
        directive = %{
          role: "system",
          content:
            "[System: This task requires codebase understanding. DISPATCH an explorer agent first: " <>
              "delegate(task: \"Scan the project — report structure, key files, patterns, and tech stack\", role: \"explorer\") " <>
              "Wait for the explorer's report before writing any code. " <>
              "For quick lookups, use thoroughness: \"quick\". For deep analysis, use \"very thorough\".]"
        }

        [directive | acc]

      # Complex coding task — at minimum read before write
      Guardrails.complex_coding_task?(message) ->
        directive = %{
          role: "system",
          content:
            "[System: This task involves code changes. Read relevant files BEFORE modifying them. " <>
              "If the task spans 5+ files or multiple domains, consider dispatching an explorer agent first: " <>
              "delegate(task: \"<specific question about the codebase>\", role: \"explorer\") " <>
              "For simpler tasks, use file_read and dir_list directly.]"
        }

        [directive | acc]

      true ->
        acc
    end
  end

  defp maybe_add_visual_observation_directive(acc, message) do
    if Guardrails.visual_observation_request?(message) and computer_use_available?() do
      directive = %{
        role: "system",
        content:
          "[System: The user is asking about what is visible on the screen or desktop. " <>
            "Do not guess from conversation text. First call computer_use with action " <>
            "`snapshot` when available, otherwise `screenshot`. After the observation, answer " <>
            "the user normally. If the observation tool fails, briefly report the concrete failure " <>
            "instead of pretending to see the screen.]"
      }

      [directive | acc]
    else
      acc
    end
  end

  defp computer_use_available? do
    Application.get_env(:optimal_system_agent, :computer_use_enabled) === true
  end

  # Inject a ONE-SHOT systematic-debugging directive when the user's message
  # reads as a bug report. This is the main-agent analogue of the `debugger`
  # subagent's method: without it the model tends to symptom-patch a pasted
  # error instead of root-causing it. Depth when debugging, silence otherwise —
  # on a non-bug turn nothing is added (zero tokens).
  #
  # Dedup reuses the Reminders per-session claim table (`:systematic_debugging`
  # key), so the directive fires AT MOST ONCE per session: the first bug turn
  # gets it, later turns (bug-shaped or not) stay silent. The guidance persists
  # in history, so re-injecting would only spend tokens repeating what the model
  # already saw — the same exactly-once contract the other reminders follow.
  defp maybe_add_debugging_directive(acc, message, %{session_id: sid})
       when is_binary(sid) and is_binary(message) do
    if Guardrails.bug_report?(message) and claim_debugging(sid) do
      [%{role: "system", content: debugging_directive()} | acc]
    else
      acc
    end
  end

  defp maybe_add_debugging_directive(acc, _message, _state), do: acc

  # First bug turn of the session returns true; later turns false. Fail-open
  # (inject) only if the claim table is somehow unavailable — never crash a turn.
  defp claim_debugging(sid) do
    Reminders.claim(sid, :systematic_debugging)
  rescue
    _ -> true
  end

  defp debugging_directive do
    "[System: This looks like a bug report. Debug it systematically — do NOT symptom-patch:\n" <>
      "1. REPRODUCE/understand the failure first: read the actual error, stack trace, and the input that triggers it.\n" <>
      "2. Read the real source AT the failure site AND the related code paths (including relevant dependency source) before concluding. Do not guess.\n" <>
      "3. Find the true ROOT CAUSE with evidence (git log/diff/bisect if it is a regression). Fix the cause, not the symptom.\n" <>
      "4. Keep the fix MINIMAL and focused; do not refactor while fixing.\n" <>
      "5. VERIFY it is actually fixed: run the failing test/command and confirm it now passes with no regressions.\n" <>
      "6. Add a REGRESSION TEST so it cannot come back.\n" <>
      "For a hard or multi-file bug, dispatch the debugger agent: delegate(task: \"<the failure>\", role: \"debugger\").]"
  end

  defp maybe_add_delegation_directive(acc, message, state) do
    if state.permission_tier == :full and Guardrails.delegation_task?(message) do
      directive = %{
        role: "system",
        content:
          "[System: TEAM DISPATCH recommended. This task has multiple independent " <>
            "deliverables. Consider assembling a team using `delegate`: " <>
            "1. Dispatch `explorer` first if you need codebase context " <>
            "2. Dispatch `planner` if the architecture is complex " <>
            "3. Then dispatch implementation agents in parallel " <>
            "Roles: explorer, planner, architect, backend, frontend, tester, debugger, " <>
            "security-auditor, code-reviewer, researcher, devops, doc-writer, refactorer, performance. " <>
            "Use background: true for research while you implement. " <>
            "Use fork: true when agents need your conversation context.]"
      }

      [directive | acc]
    else
      acc
    end
  end
end
