defmodule OptimalSystemAgent.Channels.CLI.Events do
  @moduledoc """
  Event handler registration for the CLI REPL.

  Subscribes to the Events.Bus for orchestrator progress, task tracker
  updates, proactive messages, and async agent responses — then drives
  terminal output accordingly.
  """

  alias OptimalSystemAgent.Agent.Tasks
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
        %{event: :orchestrator_task_started, task_id: task_id} ->
          Renderer.clear_line()
          IO.puts("#{bold}#{cyan}  ▶ Spawning agents...#{reset}")

          try do
            :ets.insert(:cli_signal_cache, {:active_task, task_id})
          rescue
            _ -> :ok
          end

        %{event: :orchestrator_agents_spawning, agent_count: count} ->
          Renderer.clear_line()

          IO.puts(
            "#{cyan}  ▶ Deploying #{count} agent#{if count > 1, do: "s", else: ""}#{reset}"
          )

        %{event: :orchestrator_agent_started, agent_name: name, role: role, description: desc} ->
          task_desc = if is_binary(desc) and desc != "", do: String.slice(desc, 0, 50), else: ""
          role_str = role || name
          IO.puts("#{dim}  ⏺ #{role_str}(#{task_desc})#{reset}")

        %{event: :orchestrator_agent_started, agent_name: name, role: role} ->
          role_str = role || name
          IO.puts("#{dim}  ⏺ #{role_str}#{reset}")

        %{
          event: :orchestrator_agent_progress,
          agent_name: name,
          role: role,
          current_action: action,
          tool_uses: tools,
          tokens_used: tokens
        }
        when is_binary(action) and action != "" ->
          Renderer.clear_line()
          role_str = role || name

          tokens_str =
            if is_number(tokens) and tokens >= 1000,
              do: "#{Float.round(tokens / 1000, 1)}k",
              else: "#{tokens || 0}"

          tc = tools || 0
          tl = if tc == 1, do: "tool use", else: "tool uses"

          IO.write(
            "#{dim}  ⏺ #{role_str}: #{String.slice(action, 0, 50)} (#{tc} #{tl} · #{tokens_str} tokens)#{reset}"
          )

        %{event: :orchestrator_agent_progress, agent_name: name, current_action: action}
        when is_binary(action) and action != "" ->
          Renderer.clear_line()
          IO.write("#{dim}  │  #{name}: #{String.slice(action, 0, 60)}#{reset}")

        %{
          event: :orchestrator_agent_completed,
          agent_name: name,
          role: role,
          tool_uses: tools,
          tokens_used: tokens,
          duration_ms: dur_ms
        } ->
          Renderer.clear_line()
          role_str = role || name

          tokens_str =
            if is_number(tokens) and tokens >= 1000,
              do: "#{Float.round(tokens / 1000, 1)}k",
              else: "#{tokens || 0}"

          dur_str = Renderer.format_duration_ms(dur_ms)
          tool_count = tools || 0
          tool_label = if tool_count == 1, do: "tool use", else: "tool uses"
          parts = ["#{tool_count} #{tool_label}", "#{tokens_str} tokens", dur_str] |> Enum.reject(&(&1 == ""))
          IO.puts("#{dim}  ⏺ #{role_str}#{reset}")
          IO.puts("#{dim}    ⎿  Done (#{Enum.join(parts, " · ")})#{reset}")

        %{event: :orchestrator_agent_completed, agent_name: name} ->
          Renderer.clear_line()
          IO.puts("#{dim}  ⏺ #{name}#{reset}")
          IO.puts("#{dim}    ⎿  Done#{reset}")

        %{event: :orchestrator_synthesizing} ->
          Renderer.clear_line()
          IO.puts("#{cyan}  ▶ Synthesizing results...#{reset}")

        %{event: :orchestrator_task_completed} ->
          Renderer.clear_line()
          IO.puts("#{cyan}  ▶ All agents completed#{reset}")

        %{event: :orchestrator_task_failed, reason: reason} ->
          Renderer.clear_line()
          IO.puts("#{yellow}  ▶ Orchestration failed: #{reason}#{reset}")

        %{event: :swarm_started, swarm_id: id} ->
          Renderer.clear_line()
          IO.puts("#{bold}#{cyan}  ◆ Swarm #{String.slice(id, 0, 8)}... launched#{reset}")

        %{event: :swarm_completed, swarm_id: id} ->
          Renderer.clear_line()
          IO.puts("#{cyan}  ◆ Swarm #{String.slice(id, 0, 8)}... completed#{reset}")

        %{
          event: :orchestrator_task_appraised,
          estimated_cost_usd: cost,
          estimated_hours: hours
        } ->
          Renderer.clear_line()
          cost_str = if cost < 0.01, do: "<$0.01", else: "$#{Float.round(cost, 2)}"
          hours_str = if hours < 0.1, do: "<0.1h", else: "#{Float.round(hours, 1)}h"
          IO.puts("#{dim}  ⊕ Estimated: #{cost_str} · #{hours_str}#{reset}")

        %{
          event: :orchestrator_wave_started,
          wave_number: num,
          total_waves: total,
          agent_count: count
        } ->
          Renderer.clear_line()
          IO.puts("#{cyan}  ▶ Wave #{num}/#{total} — #{count} agent#{if count > 1, do: "s", else: ""}#{reset}")

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

            IO.puts(
              "#{color}  #{bar} context: #{tokens_k}k/#{max_k}k (#{util}%)#{reset}"
            )
          end

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

  # ── Proactive Message Handler ────────────────────────────────────────

  def register_proactive_handler(session_id) do
    reset = IO.ANSI.reset()
    dim = IO.ANSI.faint()
    yellow = IO.ANSI.yellow()
    cyan = IO.ANSI.cyan()

    Bus.register_handler(:system_event, fn payload ->
      data = Map.get(payload, :data, payload)

      case data do
        %{
          event: :proactive_message,
          session_id: ^session_id,
          message: msg,
          message_type: type
        } ->
          prefix =
            case type do
              :alert -> "#{yellow}  ⚠ OSA"
              :work_complete -> "#{dim}  ✓ OSA"
              :work_failed -> "#{yellow}  ✗ OSA"
              :greeting -> "#{cyan}  OSA"
              _ -> "#{cyan}  OSA"
            end

          Renderer.clear_line()
          IO.puts("\n#{prefix} > #{msg}#{reset}\n")

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
