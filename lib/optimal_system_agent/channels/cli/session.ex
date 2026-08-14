defmodule OptimalSystemAgent.Channels.CLI.Session do
  @moduledoc """
  Session lifecycle, history management, active request tracking,
  and agent communication for the CLI REPL.

  Owns the ETS tables :cli_history and :cli_active_request, and
  provides the async/sync send helpers that drive the Spinner.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{Budget, Loop}
  alias OptimalSystemAgent.CLI.Sanitize
  alias OptimalSystemAgent.Channels.CLI.{PlanReview, Renderer, Spinner}
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.SDK.{Hook, Permission}

  @max_history 100
  @max_plan_revisions 5

  # ── ETS Init ────────────────────────────────────────────────────────

  def init_history do
    try do
      :ets.new(:cli_history, [:set, :public, :named_table])
    rescue
      ArgumentError -> :cli_history
    end
  end

  def init_active_request do
    try do
      :ets.new(:cli_active_request, [:set, :public, :named_table])
    rescue
      ArgumentError -> :cli_active_request
    end
  end

  # ── History ──────────────────────────────────────────────────────────

  def get_history(session_id) do
    case :ets.lookup(:cli_history, session_id) do
      [{^session_id, entries}] -> entries
      _ -> []
    end
  rescue
    _ -> []
  end

  def add_to_history(session_id, input) do
    current = get_history(session_id)

    updated =
      case current do
        [^input | _] -> current
        _ -> [input | Enum.take(current, @max_history - 1)]
      end

    try do
      :ets.insert(:cli_history, {session_id, updated})
    rescue
      _ -> :ok
    end
  end

  # ── Active Request Tracking ────────────────────────────────────────

  def agent_active?(session_id) do
    case :ets.lookup(:cli_active_request, session_id) do
      [{^session_id, _}] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def cancel_active_request(session_id) do
    case :ets.lookup(:cli_active_request, session_id) do
      [{^session_id, %{spinner: spinner, tool_ref: tool_ref, llm_ref: llm_ref} = req}] ->
        Spinner.stop(spinner)
        Bus.unregister_handler(:tool_call, tool_ref)
        Bus.unregister_handler(:llm_response, llm_ref)
        if cu_ref = req[:cu_ref], do: Bus.unregister_handler(:tool_result, cu_ref)
        unregister_stream_and_think_refs(req)
        :ets.delete(:cli_active_request, session_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def build_prompt(session_id) do
    bold = IO.ANSI.bright()
    cyan = IO.ANSI.cyan()
    dim = IO.ANSI.faint()
    reset = IO.ANSI.reset()

    if agent_active?(session_id),
      do: "#{dim}#{cyan}◉#{reset} ",
      else: "#{bold}#{cyan}❯#{reset} "
  end

  # ── Session Lifecycle ────────────────────────────────────────────────

  def start_new_session(old_session_id) do
    stop_session(old_session_id)

    new_session_id = "cli_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {Loop, session_id: new_session_id, channel: :cli}
      )

    register_permission_hook(new_session_id)
    dim = IO.ANSI.faint()
    reset = IO.ANSI.reset()
    IO.puts("#{dim}  session: #{new_session_id}#{reset}\n")
    new_session_id
  end

  def resume_session(target_id, messages, old_session_id) do
    stop_session(old_session_id)

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {Loop, session_id: target_id, channel: :cli, messages: messages}
      )

    register_permission_hook(target_id)

    # Replay the restored conversation into the terminal (Claude Code / Codex
    # resume parity): the Loop restores its own agent context from `messages`,
    # but the user also needs to SEE where they left off — otherwise the screen
    # is blank and resume "looks broken" even though state was restored.
    replay_transcript(messages)

    dim = IO.ANSI.faint()
    reset = IO.ANSI.reset()
    IO.puts("#{dim}  resumed: #{target_id} (#{length(messages)} messages restored)#{reset}\n")
    target_id
  end

  # Re-render a restored message list to the terminal so the prior conversation
  # is visible after /resume. Only user/assistant text turns are shown (tool and
  # system turns are agent-internal and would be noise). Best-effort: a malformed
  # turn is skipped, never crashes the resume.
  defp replay_transcript(messages) when is_list(messages) do
    turns =
      messages
      |> Enum.map(fn m -> {msg_field(m, :role), msg_field(m, :content)} end)
      |> Enum.filter(fn {role, content} ->
        role in ["user", "assistant", "agent"] and is_binary(content) and content != ""
      end)

    unless turns == [] do
      IO.puts("")

      Enum.each(turns, fn
        {"user", content} -> Renderer.print_user_message(content)
        {_assistant, content} -> Renderer.print_response(content)
      end)
    end
  rescue
    _ -> :ok
  end

  defp replay_transcript(_), do: :ok

  # Message maps may carry atom OR string keys depending on their persistence
  # round-trip; read both.
  defp msg_field(m, key) when is_map(m) do
    m[key] || m[Atom.to_string(key)]
  end

  defp msg_field(_, _), do: nil

  def stop_session(session_id) do
    # `/clear`, `/new` and `/exit` all funnel here (via `start_new_session/1`,
    # `resume_session/3` and the REPL's quit path). The CLI stops the Loop
    # directly rather than through `Runtime.SessionManager.stop_session/1`, so
    # it does NOT reach `Runtime.SessionTeardown`. Drop the session's persisted
    # compaction summary explicitly — it is verbatim conversation content and
    # must not survive into whatever session comes next.
    OptimalSystemAgent.Agent.Compactor.forget_session(session_id)

    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      _ -> :ok
    end
  end

  def set_strategy(session_id, strategy_name) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] -> GenServer.call(pid, {:set_strategy, strategy_name})
      _ -> :ok
    end
  end

  # ── Permission Hook ──────────────────────────────────────────────────

  def register_permission_hook(session_id) do
    permission_profile = Application.get_env(:optimal_system_agent, :permission_profile, :default)
    permission_fn = Permission.build_hook(permission_profile)

    hook_fn = fn %{tool_name: tool_name, arguments: args} = payload ->
      # First check saved permission rules
      case OptimalSystemAgent.Permissions.check(tool_name, args) do
        :allow ->
          {:ok, payload}

        :deny ->
          {:block, "Permanently denied by saved rule"}

        :ask ->
          # Check the default policy-based permission
          case permission_fn.(tool_name, args) do
            :allow ->
              {:ok, payload}

            {:deny, reason} ->
              # For dangerous tools, prompt the user interactively
              if interactive_permission_enabled?() and dangerous_tool?(tool_name) do
                alias OptimalSystemAgent.Channels.CLI.Permissions

                case Permissions.prompt_permission(tool_name, args) do
                  :allow_once ->
                    {:ok, payload}

                  :allow_always ->
                    OptimalSystemAgent.Permissions.save_rule(tool_name, :allow_always)
                    {:ok, payload}

                  :deny ->
                    {:block, reason}
                end
              else
                {:block, reason}
              end
          end
      end
    end

    Hook.register(:pre_tool_use, "cli_permission_#{session_id}", hook_fn, priority: 1)
  end

  defp interactive_permission_enabled? do
    Application.get_env(:optimal_system_agent, :interactive_permissions, true)
  end

  defp dangerous_tool?(tool_name) do
    tool_name in ~w(shell_execute file_delete file_write file_edit delegate)
  end

  # ── Agent Communication (Async) ──────────────────────────────────────

  def send_to_agent(input, session_id, opts \\ []) do
    spinner = Spinner.start()
    {tool_ref, cu_ref, llm_ref} = register_spinner_handlers(spinner)
    {stream_ref, streaming_state} = register_streaming_handlers(spinner, session_id)

    request_id = System.unique_integer([:positive, :monotonic])

    :ets.insert(
      :cli_active_request,
      {session_id,
       %{
         request_id: request_id,
         spinner: spinner,
         tool_ref: tool_ref,
         cu_ref: cu_ref,
         llm_ref: llm_ref,
         stream_ref: stream_ref,
         streaming_state: streaming_state,
         input: input,
         opts: opts
       }}
    )

    Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
      result = Loop.process_message(session_id, input, opts)

      Bus.emit(:system_event, %{
        event: :cli_agent_response_ready,
        session_id: session_id,
        request_id: request_id,
        result: result
      })
    end)

    :ok
  end

  # ── Agent Communication (Sync) ───────────────────────────────────────

  def send_to_agent_sync(input, session_id, opts) do
    spinner = Spinner.start()
    {tool_ref, _cu_ref, llm_ref} = register_spinner_handlers_no_cu(spinner)
    {stream_ref, streaming_state} = register_streaming_handlers(spinner, session_id)

    result = Loop.process_message(session_id, input, opts)

    Bus.unregister_handler(:tool_call, tool_ref)
    Bus.unregister_handler(:llm_response, llm_ref)
    if stream_ref, do: Bus.unregister_handler(:system_event, stream_ref)

    was_streamed = :atomics.get(streaming_state, 1) > 0

    case result do
      {:ok, response} ->
        {elapsed_ms, tool_count, total_tokens} = Spinner.stop(spinner)
        if was_streamed, do: IO.write("\n")
        unless was_streamed, do: Renderer.print_response(response)

        Renderer.show_status_line(
          elapsed_ms,
          tool_count,
          total_tokens,
          cost_from_tokens(total_tokens)
        )

        Renderer.print_separator()

      {:plan, plan_text} ->
        {elapsed_ms, _tool_count, total_tokens} = Spinner.stop(spinner)
        Renderer.show_status_line(elapsed_ms, 0, total_tokens, cost_from_tokens(total_tokens))
        handle_plan_review(plan_text, input, session_id, 0)

      {:error, reason} ->
        Spinner.stop(spinner)
        yellow = IO.ANSI.yellow()
        reset = IO.ANSI.reset()
        IO.puts("#{yellow}  error: #{reason}#{reset}\n")
    end
  end

  # ── Plan Review ──────────────────────────────────────────────────────

  def handle_plan_review(_plan_text, _original_input, _session_id, revision)
      when revision >= @max_plan_revisions do
    dim = IO.ANSI.faint()
    reset = IO.ANSI.reset()
    IO.puts("#{dim}  ✗ Max revisions reached — plan cancelled#{reset}\n")
  end

  def handle_plan_review(plan_text, original_input, session_id, revision) do
    dim = IO.ANSI.faint()
    reset = IO.ANSI.reset()

    case PlanReview.review(plan_text) do
      :approved ->
        IO.puts("#{dim}  ▶ Executing plan...#{reset}\n")

        execute_msg =
          "Execute the following approved plan. Do not re-plan — proceed directly with implementation.\n\n#{plan_text}\n\nOriginal request: #{original_input}"

        send_to_agent_sync(execute_msg, session_id, skip_plan: true)

      :rejected ->
        IO.puts("#{dim}  ✗ Plan rejected#{reset}\n")

      {:edit, feedback} ->
        IO.puts("#{dim}  ↻ Revising plan (#{revision + 1}/#{@max_plan_revisions})...#{reset}\n")

        revised_msg =
          "Revise your plan based on this feedback:\n\n#{feedback}\n\nOriginal plan:\n#{plan_text}\n\nOriginal request: #{original_input}"

        case send_to_agent_for_plan(revised_msg, session_id) do
          {:plan, new_plan_text} ->
            handle_plan_review(new_plan_text, original_input, session_id, revision + 1)

          :executed ->
            :ok
        end
    end
  end

  # ── Async Response Handling ──────────────────────────────────────────

  def handle_agent_response(session_id, result, req_id) do
    case :ets.lookup(:cli_active_request, session_id) do
      [
        {^session_id,
         %{
           request_id: ^req_id,
           spinner: spinner,
           tool_ref: tool_ref,
           llm_ref: llm_ref,
           input: original_input
         } = req}
      ] ->
        Bus.unregister_handler(:tool_call, tool_ref)
        Bus.unregister_handler(:llm_response, llm_ref)
        if cu_ref = req[:cu_ref], do: Bus.unregister_handler(:tool_result, cu_ref)
        unregister_stream_and_think_refs(req)

        yellow = IO.ANSI.yellow()
        reset = IO.ANSI.reset()

        # Check if response was streamed to terminal already
        was_streamed =
          case req[:streaming_state] do
            nil -> false
            atomics_ref -> :atomics.get(atomics_ref, 1) > 0
          end

        case result do
          {:ok, response} ->
            {elapsed_ms, tool_count, total_tokens} = Spinner.stop(spinner)

            if was_streamed do
              IO.write("\n")
            else
              Renderer.print_response(response)
            end

            Renderer.show_status_line(
              elapsed_ms,
              tool_count,
              total_tokens,
              cost_from_tokens(total_tokens)
            )

            Renderer.print_separator()

          {:plan, plan_text} ->
            {elapsed_ms, _tool_count, total_tokens} = Spinner.stop(spinner)
            Renderer.show_status_line(elapsed_ms, 0, total_tokens, cost_from_tokens(total_tokens))

            :ets.insert(
              :cli_active_request,
              {:pending_plan, session_id, plan_text, original_input}
            )

          {:error, reason} ->
            Spinner.stop(spinner)
            IO.puts("#{yellow}  error: #{reason}#{reset}\n")
        end

        :ets.delete(:cli_active_request, session_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ── Private: Plan Revision ───────────────────────────────────────────

  defp send_to_agent_for_plan(input, session_id) do
    spinner = Spinner.start()
    {tool_ref, _cu_ref, llm_ref} = register_spinner_handlers_no_cu(spinner)
    {stream_ref, _streaming_state} = register_streaming_handlers(spinner, session_id)

    result = Loop.process_message(session_id, input)

    Bus.unregister_handler(:tool_call, tool_ref)
    Bus.unregister_handler(:llm_response, llm_ref)
    if stream_ref, do: Bus.unregister_handler(:system_event, stream_ref)

    yellow = IO.ANSI.yellow()
    reset = IO.ANSI.reset()

    case result do
      {:plan, plan_text} ->
        {elapsed_ms, _tool_count, total_tokens} = Spinner.stop(spinner)
        Renderer.show_status_line(elapsed_ms, 0, total_tokens, cost_from_tokens(total_tokens))
        {:plan, plan_text}

      {:ok, response} ->
        {elapsed_ms, tool_count, total_tokens} = Spinner.stop(spinner)
        Renderer.print_response(response)

        Renderer.show_status_line(
          elapsed_ms,
          tool_count,
          total_tokens,
          cost_from_tokens(total_tokens)
        )

        Renderer.print_separator()
        :executed

      {:error, reason} ->
        Spinner.stop(spinner)
        IO.puts("#{yellow}  error: #{reason}#{reset}\n")
        :executed
    end
  end

  # ── Private: Streaming Handlers ───────────────────────────────────────

  defp register_streaming_handlers(spinner, session_id) do
    # Track whether we've started streaming (0 = not streaming, 1 = streaming)
    streaming_state = :atomics.new(1, signed: false)

    stream_ref =
      Bus.register_handler(:system_event, fn payload ->
        if Process.alive?(spinner) and Map.get(payload, :session_id) == session_id do
          case Map.get(payload, :event) do
            :streaming_token ->
              delta = Map.get(payload, :delta, "")

              # First token: switch spinner to streaming mode
              if :atomics.get(streaming_state, 1) == 0 do
                :atomics.put(streaming_state, 1, 1)
                Spinner.update(spinner, {:streaming_mode, :start})
              end

              # The primary model-text sink. Deltas are model-chosen bytes going
              # straight to the terminal, so they are scrubbed of control
              # characters here. The scrub drops characters rather than parsing
              # sequences, which is what makes it safe per-chunk: an escape split
              # across two deltas still loses its ESC in whichever chunk holds it.
              IO.write(Sanitize.scrub_block(delta))

            :thinking_delta ->
              delta = Map.get(payload, :delta, "")

              # Same, and note the wrapping SGR: an unscrubbed ESC in `delta`
              # would escape the colour OSA is applying here, not just the line.
              IO.write(IO.ANSI.light_magenta() <> Sanitize.scrub_block(delta) <> IO.ANSI.reset())

            _ ->
              :ok
          end
        end
      end)

    {stream_ref, streaming_state}
  end

  # ── Private: Spinner Bus Handlers ────────────────────────────────────

  defp register_spinner_handlers(spinner) do
    tool_ref =
      Bus.register_handler(:tool_call, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{name: n, phase: :start, args: a} ->
              Spinner.update(spinner, {:tool_start, n, a || ""})

            %{name: n, phase: :start} ->
              Spinner.update(spinner, {:tool_start, n, ""})

            %{name: n, phase: :end, duration_ms: ms} ->
              Spinner.update(spinner, {:tool_end, n, ms})

            _ ->
              :ok
          end
        end
      end)

    cu_ref =
      Bus.register_handler(:tool_result, fn payload ->
        if Process.alive?(spinner) and match?(%{name: "computer_use"}, payload) do
          case payload do
            %{result: result, success: true} ->
              Spinner.update(spinner, {:computer_use_result, result})

            %{result: result, success: false} ->
              Spinner.update(spinner, {:computer_use_error, result})

            _ ->
              :ok
          end
        end
      end)

    llm_ref =
      Bus.register_handler(:llm_response, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{usage: u} when is_map(u) and map_size(u) > 0 ->
              Spinner.update(spinner, {:llm_response, u})

            _ ->
              :ok
          end
        end
      end)

    {tool_ref, cu_ref, llm_ref}
  end

  defp register_spinner_handlers_no_cu(spinner) do
    tool_ref =
      Bus.register_handler(:tool_call, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{name: n, phase: :start, args: a} ->
              Spinner.update(spinner, {:tool_start, n, a || ""})

            %{name: n, phase: :start} ->
              Spinner.update(spinner, {:tool_start, n, ""})

            %{name: n, phase: :end, duration_ms: ms} ->
              Spinner.update(spinner, {:tool_end, n, ms})

            _ ->
              :ok
          end
        end
      end)

    llm_ref =
      Bus.register_handler(:llm_response, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{usage: u} when is_map(u) and map_size(u) > 0 ->
              Spinner.update(spinner, {:llm_response, u})

            _ ->
              :ok
          end
        end
      end)

    {tool_ref, nil, llm_ref}
  end

  defp unregister_stream_and_think_refs(req) do
    if ref = req[:stream_ref] do
      Bus.unregister_handler(:system_event, ref)
    end
  end

  # ── Private: Cost Estimation ─────────────────────────────────────────

  defp cost_from_tokens(0), do: nil

  defp cost_from_tokens(total) when total > 0 do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :anthropic)
    Budget.calculate_cost(provider, round(total * 0.7), round(total * 0.3))
  end
end
