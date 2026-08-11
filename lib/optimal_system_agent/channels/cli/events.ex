defmodule OptimalSystemAgent.Channels.CLI.Events do
  @moduledoc """
  Event handler registration for the CLI REPL.

  Subscribes to the Events.Bus for swarm/context/background-agent/limit
  signals, task tracker updates, and async agent responses — then drives
  terminal output accordingly.

  Orchestrator sub-agent progress is NOT handled here: it travels on the
  `osa:session:<id>` PubSub topic (see `Orchestrator.emit_event/2`), which
  only the SSE/TUI path consumes.
  """

  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Agent.Trajectory
  alias OptimalSystemAgent.Channels.CLI.{Renderer, TaskDisplay}
  alias OptimalSystemAgent.Events.Bus

  # ── Orchestrator / System Event Handler ─────────────────────────────

  def register_orchestrator_handler do
    try do
      :ets.new(:cli_signal_cache, [:set, :public, :named_table])
    rescue
      ArgumentError -> :cli_signal_cache
    end

    reset = IO.ANSI.reset()
    bold = IO.ANSI.bright()
    dim = IO.ANSI.faint()
    cyan = IO.ANSI.cyan()
    yellow = IO.ANSI.yellow()

    Bus.register_handler(:system_event, fn payload ->
      data = payload[:data] || payload

      case data do
        # NOTE: there are deliberately no `:orchestrator_*` clauses here.
        # `Orchestrator.emit_event/2` publishes those sub-events on the
        # `osa:session:<id>` PubSub topic with STRING names; nothing has ever
        # emitted them as atoms on `Events.Bus`, and `Events.TuiForwarder`'s
        # allowlist deliberately excludes `orchestrator_*` to avoid duplicating
        # them. The ~110 lines of renderers that used to sit here could not
        # match any payload the Bus carries. `:swarm_completed` was dead for the
        # same reason — only `:swarm_started` is emitted
        # (channels/http/api/orchestrate_routes.ex:361).
        %{event: :swarm_started, swarm_id: id} ->
          Renderer.clear_line()
          IO.puts("#{bold}#{cyan}  ◆ Swarm #{String.slice(id, 0, 8)}... launched#{reset}")

        %{
          event: :context_pressure,
          utilization: util,
          estimated_tokens: tokens,
          max_tokens: max_t
        } ->
          try do
            :ets.insert(:cli_signal_cache, {:context_pressure, util})
          rescue
            _ -> :ok
          end

          if util >= 70.0 do
            Renderer.clear_line()
            bar = Renderer.context_pressure_bar(util)
            tokens_k = Float.round(tokens / 1000, 1)
            max_k = Float.round(max_t / 1000, 1)
            color = if util >= 85.0, do: IO.ANSI.red(), else: yellow

            IO.puts("#{color}  #{bar} context: #{tokens_k}k/#{max_k}k (#{util}%)#{reset}")
          end

        # Background agent completion/failure notifications
        %{event: :background_agent_completed, role: role, result: result, duration_ms: dur} ->
          Renderer.clear_line()
          duration = Renderer.format_elapsed(dur)
          # Subagent result text is tool-derived and reaches the terminal
          # verbatim — redact before slicing so a truncated key never shows.
          preview = result |> to_string() |> Trajectory.redact() |> String.slice(0, 120)

          IO.puts(
            "\n#{IO.ANSI.green()}  ✓ Background agent \"#{role}\" completed#{reset} #{dim}(#{duration})#{reset}"
          )

          IO.puts("#{dim}    #{preview}#{reset}\n")

        %{event: :background_agent_failed, role: role, error: error, duration_ms: dur} ->
          Renderer.clear_line()
          duration = Renderer.format_elapsed(dur)

          IO.puts(
            "\n#{yellow}  ✗ Background agent \"#{role}\" failed#{reset} #{dim}(#{duration})#{reset}"
          )

          IO.puts("#{dim}    #{Trajectory.redact(to_string(error))}#{reset}\n")

        %{event: :background_agent_started, role: role, agent_id: aid} ->
          Renderer.clear_line()
          IO.puts("#{dim}  ◉ Background agent \"#{role}\" started (#{aid})#{reset}")

        # Compaction. The CLI has no spinner row to hang a live indicator on, so
        # it gets the two facts that matter as plain lines: that the agent is
        # about to spend a while folding history, and what that cost/bought.
        # Without these the REPL just went quiet for minutes mid-turn.
        %{event: :compaction_started, tokens_before: before_tokens} ->
          Renderer.clear_line()

          IO.puts(
            "#{dim}  ⋯ Compacting conversation (#{Renderer.format_tokens(before_tokens)})…#{reset}"
          )

        %{
          event: :compaction_completed,
          tokens_before: before_tokens,
          tokens_after: after_tokens,
          messages_before: msgs_before,
          messages_after: msgs_after,
          duration_ms: dur
        } ->
          Renderer.clear_line()

          IO.puts(
            "#{IO.ANSI.green()}  ✓ Compacted#{reset} #{dim}" <>
              "#{Renderer.format_tokens(before_tokens)} → #{Renderer.format_tokens(after_tokens)} " <>
              "(#{msgs_before - msgs_after} messages folded · #{Renderer.format_elapsed(dur)})#{reset}"
          )

        # Say the history is intact — a silent failure would leave the user
        # believing context was freed when nothing changed.
        %{event: :compaction_failed, reason: reason, duration_ms: dur} ->
          Renderer.clear_line()

          IO.puts(
            "#{yellow}  ✗ Compaction failed#{reset} #{dim}(#{reason} · " <>
              "#{Renderer.format_elapsed(dur)}) — conversation unchanged#{reset}"
          )

        %{event: :budget_limit_reached, current_cost: cost, limit: limit} ->
          Renderer.clear_line()

          IO.puts(
            "\n#{yellow}  ⚠ Budget limit reached ($#{Float.round(cost / 1, 4)} / $#{limit})#{reset}\n"
          )

        %{event: :turn_limit_reached, turn_count: count, limit: limit} ->
          Renderer.clear_line()
          IO.puts("\n#{yellow}  ⚠ Turn limit reached (#{count}/#{limit})#{reset}\n")

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  # ── Task Tracker Handler ─────────────────────────────────────────────

  def register_task_tracker_handler do
    Bus.register_handler(:system_event, fn payload ->
      case payload do
        %{event: event, session_id: sid}
        when event in [
               :task_tracker_task_added,
               :task_tracker_task_started,
               :task_tracker_task_completed,
               :task_tracker_task_failed,
               :task_tracker_tasks_cleared
             ] ->
          try do
            tasks = Tasks.get_tasks(sid)

            if tasks != [] do
              output = TaskDisplay.render_inline(tasks)
              Renderer.clear_line()
              IO.puts(output)

              # Cache the active task's activeForm for the spinner
              active = Enum.find(tasks, fn t -> t.status == :in_progress end)

              if active do
                form = active.metadata[:active_form] || active.title
                :ets.insert(:cli_signal_cache, {:active_task_form, form})
              else
                :ets.delete(:cli_signal_cache, :active_task_form)
              end
            end
          rescue
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  # ── Async Response Handler ───────────────────────────────────────────

  def register_response_handler(session_id, on_response) do
    Bus.register_handler(:system_event, fn payload ->
      case payload do
        %{
          event: :cli_agent_response_ready,
          session_id: ^session_id,
          result: result,
          request_id: req_id
        } ->
          on_response.(result, req_id)

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end
end
