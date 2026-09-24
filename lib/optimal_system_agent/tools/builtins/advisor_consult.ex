defmodule OptimalSystemAgent.Tools.Builtins.AdvisorConsult do
  @moduledoc """
  Model-callable tool front for `Agent.Loop.Advisor.consult/3` — the manual
  half of the advisor feature (see that module's moduledoc for the full
  design: cost cap, framing as advice-not-instructions, and the automatic
  trigger path this tool does NOT go through).

  Only `session_id` — read from the calling process's `:osa_session_id`
  (the same convention `Settings.current_session/0` and `UseSkill` rely on,
  published into the process dictionary by the loop's turn pipeline) — is
  needed: the working model supplies its own situational summary via the
  `context` argument, so this tool never needs to re-derive one from the full
  message history.
  """

  @behaviour MiosaTools.Behaviour

  alias OptimalSystemAgent.Agent.Loop.Advisor

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "advisor_consult"

  @impl true
  def description do
    "Ask a separately-configured, typically stronger advisor model a focused " <>
      "question when you want a second opinion — before committing to a plan, " <>
      "before a risky/irreversible action, or when you seem stuck. The advisor's " <>
      "reply is ADVICE, not an instruction: weigh it, do not blindly follow it. " <>
      "Capped per turn; unavailable when the operator has not configured an " <>
      "advisor model."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{
          "type" => "string",
          "description" => "The specific question you want the advisor's opinion on."
        },
        "context" => %{
          "type" => "string",
          "description" =>
            "A compact summary of the situation the advisor needs to answer well — " <>
              "what you have tried, what you are about to do, or what keeps failing. " <>
              "Keep it short; this is a paid call."
        }
      },
      "required" => ["question"]
    }
  end

  @impl true
  def execute(%{"question" => question} = args) when is_binary(question) and question != "" do
    session_id = Process.get(:osa_session_id)
    call_state = %{session_id: session_id}
    opts = if ctx = args["context"], do: [context: ctx], else: []

    case Advisor.consult(call_state, question, opts) do
      {:ok, %{advice: advice, provider: provider, model: model, cost_usd: cost}} ->
        {:ok,
         Advisor.frame(advice) <>
           "\n\n(#{provider}:#{model}, $#{Float.round(cost, 4)})"}

      {:error, :advisor_disabled} ->
        {:error, "Advisor is disabled for this session."}

      {:error, :advisor_not_configured} ->
        {:error,
         "No advisor model is configured. Set :advisor_provider and :advisor_model " <>
           "(application config or Settings) to enable this tool."}

      {:error, :cost_cap_reached} ->
        {:error,
         "Advisor cost cap reached for this turn (#{Advisor.cost_cap_usd(call_state)} USD). " <>
           "Proceed without a second opinion, or wait for the next turn."}

      {:error, reason} ->
        {:error, "Advisor call failed: #{inspect(reason)}"}
    end
  end

  def execute(_args), do: {:error, "advisor_consult requires a non-empty \"question\" argument"}
end
