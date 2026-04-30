defmodule OptimalSystemAgent.Personality do
  @moduledoc """
  Switchable personality presets for session-level tone/style overlays.

  Personalities are lightweight system prompt additions that modify HOW
  the agent communicates without changing WHAT it does. The active
  personality is injected into the dynamic context as a priority-0 block.

  Built-in presets live in this module. Users can add custom personalities
  as YAML files in ~/.osa/personalities/.
  """
  require Logger

  @presets %{
    "default" => %{
      name: "default",
      display: "Default",
      description: "Standard OSA personality — direct, competent, genuine",
      overlay: nil
    },
    "concise" => %{
      name: "concise",
      display: "Concise",
      description: "Minimal responses, no filler, just results",
      overlay: """
      Communication override: Be extremely concise. One-sentence answers when possible.
      No preambles, no summaries unless asked. Code speaks for itself. If the answer
      is a single value, just say the value.
      """
    },
    "technical" => %{
      name: "technical",
      display: "Technical",
      description: "Deep technical detail, precise terminology",
      overlay: """
      Communication override: Use precise technical terminology. Include implementation
      details, complexity analysis, and edge cases proactively. Reference RFCs, specs,
      and documentation where relevant. Assume the user is a senior engineer.
      """
    },
    "creative" => %{
      name: "creative",
      display: "Creative",
      description: "Exploratory, brainstorming-friendly, multiple approaches",
      overlay: """
      Communication override: Think divergently. Offer multiple creative approaches
      before settling on one. Use analogies and metaphors to explain. Be willing to
      explore unconventional solutions. Ask "what if" questions.
      """
    },
    "teacher" => %{
      name: "teacher",
      display: "Teacher",
      description: "Explanatory, step-by-step, builds understanding",
      overlay: """
      Communication override: Explain your reasoning step by step. Define technical
      terms before using them. Build from simple concepts to complex ones. Use examples
      liberally. Check understanding before moving forward. Your goal is to teach,
      not just to deliver results.
      """
    },
    "pair" => %{
      name: "pair",
      display: "Pair Programmer",
      description: "Collaborative, thinks aloud, asks before deciding",
      overlay: """
      Communication override: Act as a pair programming partner. Think aloud about
      trade-offs. Ask clarifying questions before making architectural decisions.
      Suggest alternatives and let the user choose. Say "I'm thinking..." when
      reasoning through a problem. Never silently make a big decision.
      """
    },
    "reviewer" => %{
      name: "reviewer",
      display: "Code Reviewer",
      description: "Critical eye, catches issues, suggests improvements",
      overlay: """
      Communication override: Approach everything with a reviewer's critical eye.
      Flag potential issues, security concerns, and maintainability problems. Rank
      findings by severity. Be direct about what's wrong, but also acknowledge
      what's done well. Think about the next developer who reads this code.
      """
    },
    "debug" => %{
      name: "debug",
      display: "Debugger",
      description: "Systematic, hypothesis-driven, methodical",
      overlay: """
      Communication override: Be methodical and hypothesis-driven. State your
      hypotheses explicitly, ranked by likelihood. Verify each one systematically.
      Show your diagnostic reasoning. Never guess — always verify with evidence.
      Binary search through the problem space.
      """
    },
    "architect" => %{
      name: "architect",
      display: "Architect",
      description: "Big picture, trade-offs, system thinking",
      overlay: """
      Communication override: Think at the system level. Consider scalability,
      maintainability, and operational concerns. Present trade-offs explicitly
      with pros/cons. Draw connections between components. Ask about requirements
      and constraints before proposing solutions. Think about failure modes.
      """
    },
    "ship" => %{
      name: "ship",
      display: "Ship It",
      description: "Fastest path to working code, minimal ceremony",
      overlay: """
      Communication override: Optimize for speed of delivery. Minimal discussion,
      maximum action. Skip optional improvements. Choose the simplest working solution.
      No refactoring unless broken. No tests unless asked. Ship first, polish later.
      One-line commit messages. Move fast.
      """
    }
  }

  @doc "Get the current active personality name."
  def current do
    OptimalSystemAgent.Settings.get("personality", "default")
  end

  @doc "Set the active personality."
  def set(name) when is_binary(name) do
    if Map.has_key?(all_personalities(), name) do
      OptimalSystemAgent.Settings.set_session(:personality, name)
      :ok
    else
      {:error, "Unknown personality '#{name}'. Available: #{available_names()}"}
    end
  end

  @doc "Get the overlay text for the current personality (nil if default)."
  def active_overlay do
    name = current()
    case Map.get(all_personalities(), name) do
      %{overlay: nil} -> nil
      %{overlay: overlay} -> "## Active Personality: #{name}\n\n#{overlay}"
      nil -> nil
    end
  end

  @doc "List all available personalities."
  def list do
    all_personalities()
    |> Enum.map(fn {_name, preset} -> preset end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Get all preset names as a comma-separated string."
  def available_names do
    all_personalities() |> Map.keys() |> Enum.sort() |> Enum.join(", ")
  end

  defp all_personalities do
    Map.merge(@presets, load_custom_personalities())
  end

  defp load_custom_personalities do
    dir = Path.expand("~/.osa/personalities")

    if File.dir?(dir) do
      dir
      |> Path.join("*.{yaml,yml}")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        case YamlElixir.read_from_file(path) do
          {:ok, %{"name" => name, "overlay" => overlay} = data} ->
            Map.put(acc, name, %{
              name: name,
              display: Map.get(data, "display", name),
              description: Map.get(data, "description", "Custom personality"),
              overlay: overlay
            })

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end
end
