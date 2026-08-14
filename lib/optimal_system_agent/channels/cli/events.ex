defmodule OptimalSystemAgent.Channels.CLI.Events do
  @moduledoc """
  Event handler registration for the CLI REPL.

  Subscribes to the Events.Bus for swarm/context/background-agent/limit
  signals, task tracker updates, and async agent responses — then drives
  terminal output accordingly.

  Orchestrator sub-agent progress is NOT handled here: it travels on the
  `osa:session:<id>` PubSub topic (see `Orchestrator.emit_event/2`), which
  only the SSE/TUI path consumes.

  ## Untrusted fields

  Almost everything interpolated into the lines below arrives from somewhere
  the operator does not control: a background agent's `role` and `result` are
  sub-agent output, `error`/`reason` are failure strings that routinely carry
  tool stderr, and `agent_id`/`swarm_id` are identifiers minted elsewhere. All
  of it goes through `OptimalSystemAgent.CLI.Sanitize` before OSA's own colour
  is wrapped around it — scrub first, colour second, so the only escapes that
  reach the terminal are the ones this module put there.

  The line builders are public (`@doc false`) rather than inlined in the
  handler closure so the bytes they emit can be asserted on directly; a handler
  registered on the global `Events.Bus` is not a testable unit.
  """

  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Agent.Trajectory
  alias OptimalSystemAgent.CLI.Sanitize
  alias OptimalSystemAgent.Channels.CLI.{Renderer, TaskDisplay}
  alias OptimalSystemAgent.Events.Bus

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @green IO.ANSI.green()

  # ── Orchestrator / System Event Handler ─────────────────────────────

  def register_orchestrator_handler do
    try do
      :ets.new(:cli_signal_cache, [:set, :public, :named_table])
    rescue
      ArgumentError -> :cli_signal_cache
    end

    reset = @reset
    dim = @dim
    yellow = @yellow

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
          IO.puts(swarm_started_line(id))

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
          IO.puts(background_completed_lines(role, result, dur))

        %{event: :background_agent_failed, role: role, error: error, duration_ms: dur} ->
          Renderer.clear_line()
          IO.puts(background_failed_lines(role, error, dur))

        %{event: :background_agent_started, role: role, agent_id: aid} ->
          Renderer.clear_line()
          IO.puts(background_started_line(role, aid))

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
          IO.puts(compaction_failed_line(reason, dur))

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

  # ── Line builders (untrusted text is scrubbed here) ──────────────────

  # A swarm id is an identifier, never a paragraph, so it goes through the
  # single-line tier: a `\n` in it would let the fake line below it be forged.
  @doc false
  @spec swarm_started_line(term()) :: String.t()
  def swarm_started_line(id) do
    short = id |> to_string() |> Sanitize.scrub_line() |> String.slice(0, 8)
    "#{@bold}#{@cyan}  ◆ Swarm #{short}... launched#{@reset}"
  end

  # `role` and `result` are sub-agent output. `Trajectory.redact/1` removes
  # secrets and does not touch control characters, so the scrub is a separate,
  # additional step — and it runs BEFORE the slice, for the same reason redact
  # does: a sequence must not be able to survive by being cut in half.
  @doc false
  @spec background_completed_lines(term(), term(), term()) :: String.t()
  def background_completed_lines(role, result, dur) do
    duration = Renderer.format_elapsed(dur)

    preview =
      result
      |> to_string()
      |> Trajectory.redact()
      |> Sanitize.scrub_line()
      |> String.slice(0, 120)

    "\n#{@green}  ✓ Background agent \"#{safe_role(role)}\" completed#{@reset} " <>
      "#{@dim}(#{duration})#{@reset}\n" <>
      "#{@dim}    #{preview}#{@reset}\n"
  end

  @doc false
  @spec background_failed_lines(term(), term(), term()) :: String.t()
  def background_failed_lines(role, error, dur) do
    duration = Renderer.format_elapsed(dur)

    detail = error |> to_string() |> Trajectory.redact() |> Sanitize.scrub_line()

    "\n#{@yellow}  ✗ Background agent \"#{safe_role(role)}\" failed#{@reset} " <>
      "#{@dim}(#{duration})#{@reset}\n" <>
      "#{@dim}    #{detail}#{@reset}\n"
  end

  @doc false
  @spec background_started_line(term(), term()) :: String.t()
  def background_started_line(role, agent_id) do
    aid = agent_id |> to_string() |> Sanitize.scrub_line()
    "#{@dim}  ◉ Background agent \"#{safe_role(role)}\" started (#{aid})#{@reset}"
  end

  # A compaction failure reason is frequently a formatted exception carrying
  # whatever the failing tool wrote, so it is untrusted like any other.
  @doc false
  @spec compaction_failed_line(term(), term()) :: String.t()
  def compaction_failed_line(reason, dur) do
    detail = reason |> to_string() |> Sanitize.scrub_line()

    "#{@yellow}  ✗ Compaction failed#{@reset} #{@dim}(#{detail} · " <>
      "#{Renderer.format_elapsed(dur)}) — conversation unchanged#{@reset}"
  end

  # The role is printed inside quotes. Besides control characters, a literal
  # `"` would let a role close the quote and continue the sentence in what
  # looks like OSA's own voice, so it is dropped too.
  defp safe_role(role) do
    role |> to_string() |> Sanitize.scrub_line() |> String.replace("\"", "")
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
                # This string is model-authored (it is the task's `activeForm`)
                # and the spinner writes it into a live status line without
                # further processing. Scrub on the way INTO the cache so every
                # reader is covered, on the single-line tier because that is the
                # only shape the spinner row can hold.
                form = Sanitize.scrub_line(active.metadata[:active_form] || active.title)
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
