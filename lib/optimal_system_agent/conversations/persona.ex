defmodule OptimalSystemAgent.Conversations.Persona do
  @moduledoc """
  Lightweight agent configuration for conversation participants.

  A Persona is a thin overlay on top of the provider/model selection — it
  shapes *how* an agent frames its responses without spawning a full agent
  session.  The Conversation.Server merges persona system-prompt additions
  into every LLM call it makes on behalf of that participant.

  ## Predefined personas

  Use `predefined/1` with one of:

    - `:devils_advocate`  — challenge every claim, surface failure modes
    - `:optimist`         — find the upside, amplify what works
    - `:pragmatist`       — focus on feasibility and concrete next steps
    - `:domain_expert`    — deep subject-matter authority, cites evidence

  ## Custom personas

  Build one directly:

      %Persona{
        name:                  "sarah",
        role:                  "Security Reviewer",
        perspective:           "Threat modeler with 10-year AppSec background",
        system_prompt_additions: "Always reason from the attacker's perspective first.",
        model:                 "claude-opus-4-5"
      }
  """

  @type t :: %__MODULE__{
          name: String.t(),
          role: String.t(),
          perspective: String.t(),
          system_prompt_additions: String.t(),
          model: String.t() | nil
        }

  defstruct [
    :name,
    :role,
    :perspective,
    :system_prompt_additions,
    model: nil
  ]

  @predefined_defs [
    devils_advocate: [
      name: "devils_advocate",
      role: "Devil's Advocate",
      perspective: "Systematic challenger — finds the weakest assumptions in any argument",
      system_prompt_additions:
        "Your role is to rigorously challenge every claim and proposal. " <>
          "Look for hidden assumptions, edge cases, failure modes, and unintended consequences. " <>
          "Do not be contrarian for its own sake — be precise about *why* something might fail. " <>
          "End each turn with the single sharpest objection you can form."
    ],
    optimist: [
      name: "optimist",
      role: "Optimist",
      perspective: "Possibility amplifier — surfaces upside and momentum",
      system_prompt_additions:
        "Your role is to identify what is working, what has potential, and what could be built upon. " <>
          "Acknowledge risks briefly but quickly pivot to how they can be mitigated. " <>
          "Energise the conversation toward action and forward progress. " <>
          "End each turn with the most compelling positive path you see."
    ],
    pragmatist: [
      name: "pragmatist",
      role: "Pragmatist",
      perspective: "Feasibility filter — grounds ideas in real constraints",
      system_prompt_additions:
        "Your role is to translate ideas into concrete, achievable steps. " <>
          "Ask: what is the minimum viable version? What does this cost in time and effort? " <>
          "What must be true for this to work? " <>
          "End each turn with the next three most important actions."
    ],
    domain_expert: [
      name: "domain_expert",
      role: "Domain Expert",
      perspective: "Subject-matter authority — cites evidence, corrects misconceptions",
      system_prompt_additions:
        "Your role is to provide deep, accurate domain knowledge. " <>
          "Cite prior art, established patterns, and known failure modes from the field. " <>
          "Correct factual errors precisely. Distinguish between consensus knowledge and contested claims. " <>
          "End each turn with the most important domain-specific insight that others may have missed."
    ]
  ]

  @doc "Return all predefined persona atoms."
  @spec predefined_keys() :: [atom()]
  def predefined_keys, do: Keyword.keys(@predefined_defs)

  @doc "Build a Persona from a predefined atom, or raise if unknown."
  @spec predefined(atom()) :: t()
  def predefined(key) when is_atom(key) do
    case Keyword.fetch(@predefined_defs, key) do
      {:ok, attrs} -> from_map(Map.new(attrs))
      :error ->
        valid = Enum.map_join(predefined_keys(), ", ", &inspect/1)
        raise ArgumentError, "Unknown predefined persona: #{inspect(key)}. Valid: #{valid}"
    end
  end

  @doc "Build a Persona from a map or keyword list of attributes."
  @spec from_map(map() | keyword()) :: t()
  def from_map(attrs) when is_list(attrs), do: from_map(Map.new(attrs))

  def from_map(attrs) when is_map(attrs) do
    %__MODULE__{
      name: to_string(attrs[:name] || attrs["name"] || "participant"),
      role: to_string(attrs[:role] || attrs["role"] || "Participant"),
      perspective: to_string(attrs[:perspective] || attrs["perspective"] || ""),
      system_prompt_additions:
        to_string(
          attrs[:system_prompt_additions] || attrs["system_prompt_additions"] || ""
        ),
      model: attrs[:model] || attrs["model"]
    }
  end

  @doc "Resolve a participant spec to a Persona. Accepts a Persona struct, atom key, or map."
  @spec resolve(t() | atom() | map()) :: t()
  def resolve(%__MODULE__{} = persona), do: persona
  def resolve(key) when is_atom(key), do: predefined(key)
  def resolve(attrs) when is_map(attrs), do: from_map(attrs)

  @doc "Build the system prompt fragment for this persona."
  @spec system_prompt(t(), String.t()) :: String.t()
  def system_prompt(%__MODULE__{} = persona, topic) do
    base = """
    You are #{persona.name}, playing the role of #{persona.role}.
    Perspective: #{persona.perspective}

    You are participating in a structured conversation about: #{topic}
    """

    if persona.system_prompt_additions != "" do
      base <> "\n" <> persona.system_prompt_additions
    else
      base
    end
  end
end
