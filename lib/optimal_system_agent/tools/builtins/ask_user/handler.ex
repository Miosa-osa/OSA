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
    # Optional ≤12-char category chip. Enforced here rather than trusted: the
    # TUI renders it in a fixed-width slot, so an over-long header would just be
    # cut off on screen with no signal to the model.
    header = normalize_header(params["header"])
    session_id = ctx.session_id || params["__session_id__"]
    ref = make_ref()
    ref_str = inspect(ref)

    register_pending(ref_str, session_id, question, options)

    Phoenix.PubSub.subscribe(
      OptimalSystemAgent.PubSub,
      "osa:ask_user:#{ref_str}"
    )

    # NOTE: the payload must stay JSON-encodable end to end — it is reshaped by
    # `Events.TuiForwarder` and written straight onto the SSE stream. A PID (the
    # old `reply_to` field) made `Jason.encode/1` fail, which silently dropped
    # the frame and left the tool blocking on a question no one ever saw.
    Bus.emit(:system_event, %{
      event: :ask_user,
      question: question,
      options: options,
      header: header,
      ref: ref_str,
      session_id: session_id
    })

    result =
      receive do
        {:ask_user_response, ^ref, answer} when is_binary(answer) ->
          answered(answer)

        {:ask_user_response, _ref, answer} when is_binary(answer) ->
          answered(answer)

        {:ask_user_answer, _survey_id, answer} when is_binary(answer) ->
          answered(answer)

        {:ask_user_declined, _survey_id} ->
          {:ok, declined_text()}
      after
        Constants.timeout_ms() ->
          {:ok, timed_out_text()}
      end

    Phoenix.PubSub.unsubscribe(OptimalSystemAgent.PubSub, "osa:ask_user:#{ref_str}")
    deregister_pending(ref_str)

    result
  end

  # ── Private ───────────────────────────────────────────────────────────

  # An answer that came back empty (the operator dismissed the picker without
  # choosing) is a decline, not an answer.
  defp answered(answer) do
    case String.trim(answer) do
      "" -> {:ok, declined_text()}
      trimmed -> {:ok, "User answered: #{trimmed}"}
    end
  end

  # Both escape hatches resolve to an `{:ok, _}` model-readable result rather
  # than an error: a declined question is an answer ("no answer"), not a tool
  # failure, and must not abort the turn or feed the doom-loop detector.
  # The wording is matched by `ToolError.user_decision?/1`.
  defp declined_text do
    "No answer — you declined to answer this question. " <>
      "Do not ask it again; continue with your best judgment and state the assumption you made."
  end

  defp timed_out_text do
    "No answer — the question timed out with no response. " <>
      "Do not ask it again; continue with your best judgment and state the assumption you made."
  end

  # A blank/oversized header is dropped rather than shown clipped.
  defp normalize_header(h) when is_binary(h) do
    case String.trim(h) do
      "" -> nil
      trimmed -> if String.length(trimmed) <= 12, do: trimmed, else: nil
    end
  end

  defp normalize_header(_), do: nil

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
