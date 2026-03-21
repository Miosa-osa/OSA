defmodule OptimalSystemAgent.Channels.CLI.Session do
  @moduledoc """
  Session lifecycle, history management, active request tracking,
  and agent communication for the CLI REPL.

  Owns the ETS tables :cli_history and :cli_active_request, and
  provides the async/sync send helpers that drive the Spinner.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{Loop, Tasks}
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
    dim = IO.ANSI.faint()
    reset = IO.ANSI.reset()
    IO.puts("#{dim}  resumed: #{target_id} (#{length(messages)} messages restored)#{reset}\n")
    target_id
  end

  def stop_session(session_id) do
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
    permission_fn = Permission.build_hook(:default)

    hook_fn = fn %{tool_name: tool_name, arguments: args} = payload ->
      case permission_fn.(tool_name, args) do
        :allow -> {:ok, payload}
        {:deny, reason} -> {:block, reason}
      end
    end

    Hook.register(:pre_tool_use, "cli_permission_#{session_id}", hook_fn, priority: 1)
  end

  # ── Agent Communication (Async) ──────────────────────────────────────

  def send_to_agent(input, session_id, opts \\ []) do
    spinner = Spinner.start()
    {tool_ref, cu_ref, llm_ref} = register_spinner_handlers(spinner)

    request_id = System.unique_integer([:positive, :monotonic])

    :ets.insert(:cli_active_request, {session_id, %{
      request_id: request_id,
      spinner: spinner,
      tool_ref: tool_ref,
      cu_ref: cu_ref,
      llm_ref: llm_ref,
      input: input,
      opts: opts
    }})

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

    result = Loop.process_message(session_id, input, opts)

    Bus.unregister_handler(:tool_call, tool_ref)
    Bus.unregister_handler(:llm_response, llm_ref)

    case result do
      {:ok, response} ->
        {elapsed_ms, tool_count, total_tokens} = Spinner.stop(spinner)
        Renderer.show_status_line(elapsed_ms, tool_count, total_tokens)
        Renderer.print_response(response)
        Renderer.print_separator()

      {:plan, plan_text} ->
        {elapsed_ms, _tool_count, total_tokens} = Spinner.stop(spinner)
        Renderer.show_status_line(elapsed_ms, 0, total_tokens)
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
      [{^session_id,
        %{
          request_id: ^req_id,
          spinner: spinner,
          tool_ref: tool_ref,
          llm_ref: llm_ref,
          input: original_input
        } = req}] ->
        Bus.unregister_handler(:tool_call, tool_ref)
        Bus.unregister_handler(:llm_response, llm_ref)
        if cu_ref = req[:cu_ref], do: Bus.unregister_handler(:tool_result, cu_ref)

        yellow = IO.ANSI.yellow()
        reset = IO.ANSI.reset()

        case result do
          {:ok, response} ->
            {elapsed_ms, tool_count, total_tokens} = Spinner.stop(spinner)
            Renderer.show_status_line(elapsed_ms, tool_count, total_tokens)
            Renderer.print_response(response)
            Renderer.print_separator()

          {:plan, plan_text} ->
            {elapsed_ms, _tool_count, total_tokens} = Spinner.stop(spinner)
            Renderer.show_status_line(elapsed_ms, 0, total_tokens)
            :ets.insert(:cli_active_request, {:pending_plan, session_id, plan_text, original_input})

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

    result = Loop.process_message(session_id, input)

    Bus.unregister_handler(:tool_call, tool_ref)
    Bus.unregister_handler(:llm_response, llm_ref)

    yellow = IO.ANSI.yellow()
    reset = IO.ANSI.reset()

    case result do
      {:plan, plan_text} ->
        {elapsed_ms, _tool_count, total_tokens} = Spinner.stop(spinner)
        Renderer.show_status_line(elapsed_ms, 0, total_tokens)
        {:plan, plan_text}

      {:ok, response} ->
        {elapsed_ms, tool_count, total_tokens} = Spinner.stop(spinner)
        Renderer.show_status_line(elapsed_ms, tool_count, total_tokens)
        Renderer.print_response(response)
        Renderer.print_separator()
        :executed

      {:error, reason} ->
        Spinner.stop(spinner)
        IO.puts("#{yellow}  error: #{reason}#{reset}\n")
        :executed
    end
  end

  # ── Private: Spinner Bus Handlers ────────────────────────────────────

  defp register_spinner_handlers(spinner) do
    tool_ref =
      Bus.register_handler(:tool_call, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{name: n, phase: :start, args: a} -> Spinner.update(spinner, {:tool_start, n, a || ""})
            %{name: n, phase: :start} -> Spinner.update(spinner, {:tool_start, n, ""})
            %{name: n, phase: :end, duration_ms: ms} -> Spinner.update(spinner, {:tool_end, n, ms})
            _ -> :ok
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
            %{name: n, phase: :start, args: a} -> Spinner.update(spinner, {:tool_start, n, a || ""})
            %{name: n, phase: :start} -> Spinner.update(spinner, {:tool_start, n, ""})
            %{name: n, phase: :end, duration_ms: ms} -> Spinner.update(spinner, {:tool_end, n, ms})
            _ -> :ok
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
end
