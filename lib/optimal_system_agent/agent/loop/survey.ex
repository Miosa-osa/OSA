defmodule OptimalSystemAgent.Agent.Loop.Survey do
  @moduledoc """
  Interactive survey dialog — asks the user questions via the TUI and waits for answers.

  Uses two ETS tables:
  - `:osa_cancel_flags` — checked each poll iteration to abort on session cancel.
  - `:osa_survey_answers` — written by the HTTP endpoint that handles survey submissions;
    read here to receive the answer.

  The caller blocks (polls every 200 ms) until the user responds, skips, or the
  timeout expires. Intended for use inside tool implementations (e.g. `ask_user`).
  """
  require Logger

  alias OptimalSystemAgent.Agent.Attendance
  alias OptimalSystemAgent.Events.Bus

  @cancel_table :osa_cancel_flags
  @survey_table :osa_survey_answers

  @doc """
  Ask the user interactive questions via the TUI survey dialog.
  Blocks the calling process until the user responds or timeout (120s default).

  Returns `{:ok, answers}` | `{:skipped}` | `{:error, :timeout}` |
  `{:error, :cancelled}` | `{:error, :unattended}`.

  ## Gated on someone being there

  Same shape as `Loop.PermissionBroker.await/3` and the same defect: a 120 s
  poll whose only terminator is a human. `Agent.Attendance` is consulted first,
  and a session nobody is attached to returns `{:error, :unattended}` at once
  rather than emitting a question into a topic with no readers and then sleeping
  two minutes. `ask_user`'s handler already maps a non-answer onto an
  instruction to proceed on a stated assumption, so this costs the model
  nothing but two minutes it never had.

  `attended: true | false` overrides the derivation for tests.

  ## Question format

      %{
        text: "Which editor do you use most?",
        multi_select: false,
        options: [
          %{label: "Neovim", description: "Fast keyboard-driven workflow"},
          %{label: "VS Code", description: "Feature-rich and extensible"}
        ],
        skippable: true
      }
  """
  @spec ask(String.t(), String.t(), list(map()), keyword()) ::
          {:ok, term()} | {:skipped} | {:error, :timeout} | {:error, :cancelled}
  def ask(session_id, survey_id, questions, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    attended? =
      case Keyword.get(opts, :attended) do
        v when is_boolean(v) -> v
        _ -> Attendance.attended?(Keyword.get(opts, :state) || session_id)
      end

    if attended? do
      Bus.emit(:system_event, %{
        event: :ask_user_question,
        session_id: session_id,
        data: %{
          survey_id: survey_id,
          questions: questions,
          skippable: Keyword.get(opts, :skippable, true)
        }
      })

      Logger.info(
        "[survey] waiting up to #{div(timeout, 1000)}s for an answer to #{survey_id} " <>
          "(session #{inspect(session_id)})"
      )

      started = System.monotonic_time(:millisecond)
      result = poll_answer(session_id, survey_id, timeout)
      elapsed = System.monotonic_time(:millisecond) - started

      case result do
        {:error, :timeout} ->
          Logger.warning("[survey] #{survey_id} timed out after #{elapsed}ms with no answer")

        _ ->
          Logger.info("[survey] #{survey_id} resolved #{inspect(result)} after #{elapsed}ms")
      end

      result
    else
      Logger.info(
        "[survey] not asking #{survey_id} — nobody can answer on session " <>
          "#{inspect(session_id)} (#{Attendance.reason(session_id)})"
      )

      {:error, :unattended}
    end
  end

  # --- Private ---

  defp poll_answer(_session_id, _survey_id, timeout) when timeout <= 0 do
    {:error, :timeout}
  end

  defp poll_answer(session_id, survey_id, timeout) do
    case :ets.lookup(@cancel_table, session_id) do
      [{_, true}] ->
        {:error, :cancelled}

      _ ->
        key = {session_id, survey_id}

        case :ets.lookup(@survey_table, key) do
          [{^key, :skipped}] ->
            :ets.delete(@survey_table, key)
            {:skipped}

          [{^key, answers}] ->
            :ets.delete(@survey_table, key)
            {:ok, answers}

          [] ->
            Process.sleep(200)
            poll_answer(session_id, survey_id, timeout - 200)
        end
    end
  end
end
