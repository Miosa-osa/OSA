defmodule OptimalSystemAgent.Tools.Builtins.AskUser do
  @moduledoc """
  Interactive prompting tool — lets the LLM ask the user questions mid-task.

  Emits an event on the Bus and waits for the user's response.
  The channel (SSE/TUI) renders the question and relays the answer back.
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Events.Bus

  @timeout_ms 300_000

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "ask_user"

  @impl true
  def description,
    do:
      "Ask the user a question to clarify requirements. Use when you need input before proceeding."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{"type" => "string", "description" => "The question to ask the user"},
        "options" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Optional multiple choice options"
        }
      },
      "required" => ["question"]
    }
  end

  @impl true
  def execute(%{"question" => question} = params) do
    options = params["options"] || []
    session_id = params["__session_id__"]
    ref = make_ref()
    ref_str = inspect(ref)
    caller = self()

    # Register pending question so TUI can poll GET /sessions/:id/pending_questions
    if is_binary(session_id) and session_id != "" do
      try do
        :ets.insert(
          :osa_pending_questions,
          {ref_str,
           %{
             session_id: session_id,
             question: question,
             options: options,
             asked_at: DateTime.utc_now() |> DateTime.to_iso8601()
           }}
        )
      rescue
        _ -> :ok
      end
    end

    # Subscribe to PubSub for receiving the answer from the TUI survey dialog
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:ask_user:#{ref_str}")

    # Emit ask_user event — the SSE handler transforms this into ask_user_question
    # which triggers the TUI's SurveyDialog popup
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
        # Direct process message (legacy path)
        {:ask_user_response, ^ref, answer} when is_binary(answer) ->
          {:ok, "User answered: #{answer}"}

        {:ask_user_response, _ref, answer} when is_binary(answer) ->
          {:ok, "User answered: #{answer}"}

        # Answer from TUI survey dialog via PubSub
        {:ask_user_answer, _survey_id, answer} when is_binary(answer) ->
          {:ok, "User answered: #{answer}"}
      after
        @timeout_ms ->
          {:error, "User did not respond within 5 minutes"}
      end

    # Cleanup
    Phoenix.PubSub.unsubscribe(OptimalSystemAgent.PubSub, "osa:ask_user:#{ref_str}")

    try do
      :ets.delete(:osa_pending_questions, ref_str)
    rescue
      _ -> :ok
    end

    result
  end

  def execute(_), do: {:error, "Missing required parameter: question"}
end
