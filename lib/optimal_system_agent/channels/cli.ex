defmodule OptimalSystemAgent.Channels.CLI do
  @moduledoc """
  Interactive CLI REPL — clean, colored, responsive.

  Supports streaming responses, animated spinner with elapsed time/token count,
  readline-style line editing with arrow keys and history, and markdown rendering.

  Start with: mix osa.chat

  Sub-modules:
    - CLI.Renderer            — banner, response display, status line, formatters
    - CLI.Session             — history, active request tracking, agent send helpers
    - CLI.Events              — Bus event handler registration
    - CLI.ComputerUseDispatch — smart computer-use intent classification and dispatch
    - CLI.LineEditor          — readline-style line editing
    - CLI.Spinner             — animated progress spinner
    - CLI.Markdown            — terminal markdown renderer
    - CLI.PlanReview          — interactive plan review UI
    - CLI.TaskDisplay         — inline task list rendering
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop

  alias OptimalSystemAgent.Channels.CLI.{
    Commands,
    ComputerUseDispatch,
    Events,
    LineEditor,
    MessageQueue,
    Renderer,
    Session
  }

  alias OptimalSystemAgent.Channels.NoiseFilter

  def start do
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())

    # First-run setup wizard
    if OptimalSystemAgent.Onboarding.first_run?() do
      case OptimalSystemAgent.CLI.Setup.run() do
        :ok ->
          IO.puts("")

        :skip ->
          IO.puts(
            "\n#{IO.ANSI.faint()}  Skipped setup — use /login or set env vars#{IO.ANSI.reset()}\n"
          )
      end
    end

    Renderer.print_banner()

    # Check for session resume
    {session_id, messages} =
      case Application.get_env(:optimal_system_agent, :resume_session_id) do
        nil ->
          {"cli_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower), []}

        resume_id ->
          Application.delete_env(:optimal_system_agent, :resume_session_id)

          case OptimalSystemAgent.Agent.SessionPersistence.load(resume_id) do
            {:ok, msgs} ->
              IO.puts(
                "#{IO.ANSI.faint()}  Resumed session: #{resume_id} (#{length(msgs)} messages)#{IO.ANSI.reset()}\n"
              )

              {resume_id, msgs}

            {:error, _} ->
              IO.puts(
                "#{IO.ANSI.yellow()}  Could not resume #{resume_id} — starting new session#{IO.ANSI.reset()}\n"
              )

              {"cli_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower), []}
          end
      end

    # Tag the CLI session with its working directory so it persists a real
    # working_dir (enabling cwd-scoped --continue / directory-scoped resume)
    # instead of the unset app-env nil.
    working_dir = File.cwd!()

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {Loop,
         session_id: session_id, channel: :cli, messages: messages, working_dir: working_dir}
      )

    Session.register_permission_hook(session_id)

    Events.register_orchestrator_handler()
    Events.register_task_tracker_handler()

    Session.init_history()
    Session.init_active_request()

    # Start message queue for debounce batching
    MessageQueue.start_link(session_id)

    Events.register_response_handler(session_id, fn result, req_id ->
      Session.handle_agent_response(session_id, result, req_id)
      # Signal queue that agent is done — dispatch next queued message
      MessageQueue.agent_finished(session_id)
    end)

    loop(session_id)
  end

  defp loop(session_id) do
    case :ets.lookup(:cli_active_request, :pending_plan) do
      [{:pending_plan, ^session_id, plan_text, original_input}] ->
        :ets.delete(:cli_active_request, :pending_plan)
        Session.handle_plan_review(plan_text, original_input, session_id, 0)

      _ ->
        :ok
    end

    prompt = Session.build_prompt(session_id)
    history = Session.get_history(session_id)

    case LineEditor.readline(prompt, history) do
      :eof ->
        exit_cli(session_id)

      :interrupt ->
        if Session.agent_active?(session_id) do
          Session.cancel_active_request(session_id)
          IO.puts("\n#{IO.ANSI.yellow()}  ✗ Cancelled#{IO.ANSI.reset()}")
        end

        loop(session_id)

      {:ok, ""} ->
        loop(session_id)

      {:ok, input} ->
        input = input |> sanitize_input() |> String.trim()

        if input == "" do
          loop(session_id)
        else
          case input do
            x when x in ["exit", "quit"] ->
              exit_cli(session_id)

            "clear" ->
              IO.write(IO.ANSI.clear() <> IO.ANSI.home())
              Renderer.print_banner()
              IO.puts("")
              loop(session_id)

            _ ->
              if Session.agent_active?(session_id) do
                IO.puts(
                  "#{IO.ANSI.faint()}  (agent is working — Ctrl+C to cancel)#{IO.ANSI.reset()}"
                )

                loop(session_id)
              else
                Session.add_to_history(session_id, input)
                # Echo user message with styled header
                unless String.starts_with?(input, "/") do
                  Renderer.print_user_message(input)
                end

                next = process_input(input, session_id)
                loop(next)
              end
          end
        end
    end
  rescue
    e ->
      Logger.warning("CLI loop error: #{Exception.message(e)}")
      loop(session_id)
  end

  # ── Exit ─────────────────────────────────────────────────────────────
  #
  # `System.halt/1` stops the VM immediately: no `terminate/2`, no supervisor
  # shutdown, nothing queued in any mailbox gets serviced. The turn-end spend
  # flush is synchronous and in the loop's own process, so it survived that;
  # the transcript save is a cast the loop never got to run, so it did not.
  # The result on this machine was 1,684 spend files with no sibling
  # transcript — every session where the user hit a defect was discarded on the
  # way out, which is why "OSA sometimes stops early" had no evidence to look
  # at.
  #
  # Flush first, then halt. Bounded inside `flush_sync/2` so a mid-turn exit
  # cannot hang the shutdown.
  @doc false
  @spec exit_cli(String.t()) :: no_return()
  def exit_cli(session_id) do
    _ = OptimalSystemAgent.Agent.SessionPersistence.flush_sync(session_id)
    Renderer.print_goodbye()
    System.halt(0)
  end

  defp sanitize_input(input) do
    input
    |> :unicode.characters_to_nfc_binary()
    |> case do
      {:error, _, _} -> input
      bin when is_binary(bin) -> bin
      _ -> input
    end
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp process_input(input, session_id) do
    if String.starts_with?(input, "/") do
      cmd = String.trim_leading(input, "/")
      handle_command(cmd, session_id)
    else
      if computer_use_enabled?() and ComputerUseDispatch.intent?(input) do
        ComputerUseDispatch.dispatch(input, session_id)
      else
        filtered =
          NoiseFilter.filter_and_reply(input, nil, fn ack ->
            if ack != "" do
              IO.puts("#{IO.ANSI.faint()}  #{ack}#{IO.ANSI.reset()}")
            end
          end)

        unless filtered do
          case MessageQueue.submit(session_id, input) do
            %{status: :queued, position: position} ->
              IO.puts("#{IO.ANSI.faint()}  Queued at position #{position}#{IO.ANSI.reset()}")

            _accepted ->
              :ok
          end
        end
      end

      session_id
    end
  end

  # ── Command Handling ─────────────────────────────────────────────────

  defp handle_command(cmd, session_id) do
    Commands.dispatch(cmd, session_id)
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp computer_use_enabled? do
    Application.get_env(:optimal_system_agent, :computer_use_enabled) === true
  end
end
