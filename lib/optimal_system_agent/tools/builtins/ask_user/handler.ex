defmodule OptimalSystemAgent.Tools.Builtins.AskUser.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `ask_user`.

  Behaviour split:
    * `validate/2`           — checks input shape (cheap)
    * `check_permissions/2`  — always allowed (no filesystem or external access)
    * `execute/2`            — emits Bus event, blocks on PubSub reply
  """

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Tools.Builtins.AskUser.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"question" => q} = input, _ctx) when is_binary(q) and q != "",
    do: {:ok, input}

  def validate(%{"question" => _}, _ctx),
    do: {:error, "question must be a non-empty string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: question", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"question" => question} = params, ctx) do
    options = params["options"] || []
    session_id = ctx.session_id || params["__session_id__"]
    ref = make_ref()
    ref_str = inspect(ref)
    caller = self()

    register_pending(ref_str, session_id, question, options)

    Phoenix.PubSub.subscribe(
      OptimalSystemAgent.PubSub,
      "osa:ask_user:#{ref_str}"
    )

    Bus.emit(:system_event, %{
      event: :ask_user,
      question: question,
      options: options,
      ref: ref_str,
      reply_to: caller,
      session_id: session_id
    })

    result =
      receive do
        {:ask_user_response, ^ref, answer} when is_binary(answer) ->
          {:ok, "User answered: #{answer}"}

        {:ask_user_response, _ref, answer} when is_binary(answer) ->
          {:ok, "User answered: #{answer}"}

        {:ask_user_answer, _survey_id, answer} when is_binary(answer) ->
          {:ok, "User answered: #{answer}"}
      after
        Constants.timeout_ms() ->
          {:error, "User did not respond within 5 minutes"}
      end

    Phoenix.PubSub.unsubscribe(OptimalSystemAgent.PubSub, "osa:ask_user:#{ref_str}")
    deregister_pending(ref_str)

    result
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp register_pending(ref_str, session_id, question, options) do
    if is_binary(session_id) and session_id != "" do
      try do
        :ets.insert(Constants.pending_questions_table(), {
          ref_str,
          %{
            session_id: session_id,
            question: question,
            options: options,
            asked_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })
      rescue
        _ -> :ok
      end
    end
  end

  defp deregister_pending(ref_str) do
    try do
      :ets.delete(Constants.pending_questions_table(), ref_str)
    rescue
      _ -> :ok
    end
  end
end
