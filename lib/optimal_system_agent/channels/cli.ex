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
    ComputerUseDispatch,
    Events,
    LineEditor,
    Renderer,
    Session
  }
  alias OptimalSystemAgent.Channels.NoiseFilter

  def start do
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    Renderer.print_banner()

    session_id = "cli_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {Loop, session_id: session_id, channel: :cli}
      )

    Session.register_permission_hook(session_id)

    Events.register_orchestrator_handler()
    Events.register_task_tracker_handler()

    Session.init_history()
    Session.init_active_request()

    Events.register_response_handler(session_id, fn result, req_id ->
      Session.handle_agent_response(session_id, result, req_id)
    end)

    Events.register_proactive_handler(session_id)

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
        Renderer.print_goodbye()
        System.halt(0)

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
              Renderer.print_goodbye()
              System.halt(0)

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
          Session.send_to_agent(input, session_id)
        end
      end

      session_id
    end
  end


  # ── Command Handling ─────────────────────────────────────────────────

  defp handle_command(cmd, session_id) do
    cmd_name = String.split(cmd, ~r/\s+/) |> hd()
    IO.puts("#{IO.ANSI.yellow()}  error: unknown command '/#{cmd_name}'#{IO.ANSI.reset()}")
    IO.puts("#{IO.ANSI.faint()}  Type /help to see available commands#{IO.ANSI.reset()}\n")
    _ = session_id
    session_id
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp computer_use_enabled? do
    Application.get_env(:optimal_system_agent, :computer_use_enabled) === true
  end
end
