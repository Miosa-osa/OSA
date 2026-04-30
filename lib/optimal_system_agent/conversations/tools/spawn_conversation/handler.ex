defmodule OptimalSystemAgent.Conversations.Tools.SpawnConversation.Handler do
  @moduledoc """
  Validation and execution logic for `spawn_conversation`.

    * `validate/2`  — type-check required fields
    * `execute/2`   — build participants, start Server, return summary
  """

  require Logger

  alias OptimalSystemAgent.Conversations.{Server, Persona}
  alias OptimalSystemAgent.Conversations.Tools.SpawnConversation.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(
        %{"type" => type, "topic" => topic, "participant_roles" => roles} = input,
        _ctx
      )
      when is_binary(type) and is_binary(topic) and is_list(roles),
      do: {:ok, input}

  def validate(%{"type" => _, "topic" => _, "participant_roles" => _}, _ctx),
    do: {:error, "type and topic must be strings; participant_roles must be an array", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: type, topic, participant_roles", -32_602}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(params, _ctx) do
    type = parse_type(params["type"])
    topic = to_string(params["topic"] || "")
    raw_roles = params["participant_roles"] || []
    max_turns = params["max_turns"] || Constants.default_max_turns()
    strategy = parse_strategy(params["strategy"])
    facilitator_role = params["facilitator_role"]

    if String.trim(topic) == "" do
      {:ok, "Error: topic is required for spawn_conversation."}
    else
      participants = build_participants(raw_roles)

      opts =
        [
          type: type,
          topic: topic,
          participants: participants,
          max_turns: max_turns,
          strategy: strategy
        ]
        |> maybe_add_facilitator(facilitator_role)

      Logger.info(
        "[SpawnConversation] starting #{type} conversation: #{inspect(topic)} participants=#{length(participants)}"
      )

      case Server.start_link(opts) do
        {:ok, pid} ->
          case Server.run(pid) do
            {:ok, summary} -> {:ok, format_summary(summary)}
            {:error, reason} -> {:ok, "Conversation failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:ok, "Failed to start conversation: #{inspect(reason)}"}
      end
    end
  rescue
    e ->
      Logger.warning("[SpawnConversation] execute exception: #{Exception.message(e)}")
      {:ok, "Conversation error: #{Exception.message(e)}"}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp build_participants(roles) do
    predefined = Persona.predefined_keys() |> Enum.map(&to_string/1)

    Enum.map(roles, fn role ->
      role_str = to_string(role)

      if role_str in predefined do
        Persona.predefined(String.to_existing_atom(role_str))
      else
        %Persona{
          name: slug(role_str),
          role: role_str,
          perspective: "#{role_str} perspective",
          system_prompt_additions: "Speak from the perspective of a #{role_str}."
        }
      end
    end)
  end

  defp parse_type(nil), do: :brainstorm
  defp parse_type("brainstorm"), do: :brainstorm
  defp parse_type("design_review"), do: :design_review
  defp parse_type("red_team"), do: :red_team
  defp parse_type("user_panel"), do: :user_panel
  defp parse_type(_), do: :brainstorm

  defp parse_strategy(nil), do: :round_robin
  defp parse_strategy("round_robin"), do: :round_robin
  defp parse_strategy("facilitator"), do: :facilitator
  defp parse_strategy("weighted"), do: :weighted
  defp parse_strategy(_), do: :round_robin

  defp maybe_add_facilitator(opts, nil), do: opts

  defp maybe_add_facilitator(opts, role) do
    predefined = Persona.predefined_keys() |> Enum.map(&to_string/1)

    facilitator =
      if to_string(role) in predefined do
        Persona.predefined(String.to_existing_atom(to_string(role)))
      else
        %Persona{
          name: slug(role),
          role: to_string(role),
          perspective: "Neutral facilitator",
          system_prompt_additions: "Your role is to facilitate and guide the conversation."
        }
      end

    Keyword.merge(opts, strategy: :facilitator, facilitator: facilitator)
  end

  defp format_summary(summary) do
    [
      "## Conversation Summary: #{summary.topic}",
      "",
      summary.summary,
      "",
      format_list("Key Decisions", summary.key_decisions),
      format_list("Action Items", summary.action_items),
      format_list("Dissenting Views", summary.dissenting_views),
      format_list("Open Questions", summary.open_questions),
      "",
      "_#{summary.participant_count} participants · #{summary.turn_count} turns_"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_list(_label, []), do: nil

  defp format_list(label, items) do
    rows = Enum.map_join(items, "\n", fn item -> "- #{item}" end)
    "**#{label}**\n#{rows}"
  end

  defp slug(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^\w]/, "_")
    |> String.trim("_")
  end
end
