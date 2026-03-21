defmodule OptimalSystemAgent.Conversations.Tools.SpawnConversation do
  @moduledoc """
  Tool that allows any agent to spawn a structured multi-agent conversation.

  The tool blocks until the conversation completes and returns the Weaver
  summary. The calling agent receives a structured text summary it can reason
  over and act on.

  ## Parameters

    * `type`              - conversation type: brainstorm, design_review, red_team, user_panel
    * `topic`             - what the conversation is about
    * `participant_roles` - list of role names (predefined personas or custom role strings)
    * `max_turns`         - optional turn limit (default: 20)
    * `strategy`          - optional turn strategy: round_robin, facilitator, weighted
    * `facilitator_role`  - optional facilitator persona (only for facilitator strategy)

  ## Predefined persona roles

  Use these string values in `participant_roles`:
  `devils_advocate`, `optimist`, `pragmatist`, `domain_expert`
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  alias OptimalSystemAgent.Conversations.{Server, Persona}

  @impl true
  def name, do: "spawn_conversation"

  @impl true
  def description do
    "Spawn a structured multi-agent conversation and receive its summary. " <>
      "Supports brainstorm, design_review, red_team, and user_panel types. " <>
      "Participants are AI personas that debate and discuss the topic. " <>
      "Returns key decisions, action items, dissenting views, and open questions."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["type", "topic", "participant_roles"],
      "properties" => %{
        "type" => %{
          "type" => "string",
          "enum" => ["brainstorm", "design_review", "red_team", "user_panel"],
          "description" => "The conversation format to use."
        },
        "topic" => %{
          "type" => "string",
          "description" => "The subject, question, or proposal the conversation should address."
        },
        "participant_roles" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "List of participant roles. Use predefined keys (devils_advocate, optimist, pragmatist, domain_expert) or custom role strings.",
          "minItems" => 2,
          "maxItems" => 8
        },
        "max_turns" => %{
          "type" => "integer",
          "description" => "Maximum number of turns (default: 20).",
          "minimum" => 2,
          "maximum" => 50
        },
        "strategy" => %{
          "type" => "string",
          "enum" => ["round_robin", "facilitator", "weighted"],
          "description" => "Turn-taking strategy (default: round_robin)."
        },
        "facilitator_role" => %{
          "type" => "string",
          "description" =>
            "Role for the facilitator when strategy=facilitator. Defaults to pragmatist."
        }
      }
    }
  end

  @impl true
  def safety, do: :write_safe

  @impl true
  def execute(params) do
    type = parse_type(params["type"])
    topic = to_string(params["topic"] || "")
    raw_roles = params["participant_roles"] || []
    max_turns = params["max_turns"] || 20
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

      Logger.info("[SpawnConversation] starting #{type} conversation: #{inspect(topic)} participants=#{length(participants)}")

      case Server.start_link(opts) do
        {:ok, pid} ->
          case Server.run(pid) do
            {:ok, summary} ->
              {:ok, format_summary(summary)}

            {:error, reason} ->
              {:ok, "Conversation failed: #{inspect(reason)}"}
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

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_participants(roles) do
    predefined = Persona.predefined_keys() |> Enum.map(&to_string/1)

    roles
    |> Enum.map(fn role ->
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
    sections = [
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

    sections
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
