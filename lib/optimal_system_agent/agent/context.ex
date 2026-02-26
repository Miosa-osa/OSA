defmodule OptimalSystemAgent.Agent.Context do
  @moduledoc """
  Context builder — assembles the system prompt from layered sources.

  Prompt assembly order:
    1. Identity block (who the agent is)
    2. Bootstrap files (IDENTITY.md, SOUL.md, USER.md)
    3. Long-term memory (MEMORY.md)
    4. Machine addendums (active machine prompt fragments)
    5. Active skills documentation
    6. Communication profile (if contact known)
    7. Memory bulletin (Cortex periodic synthesis)
    8. Runtime context (timestamp, channel, session info)
  """

  alias OptimalSystemAgent.Skills.Registry, as: Skills

  @bootstrap_dir Application.compile_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")

  def build(state) do
    system_prompt =
      [
        identity_block(),
        bootstrap_files(),
        memory_block(),
        machines_block(),
        skills_block(),
        runtime_block(state),
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n---\n\n")

    system_msg = %{role: "system", content: system_prompt}

    %{messages: [system_msg | state.messages]}
  end

  defp identity_block do
    """
    # OptimalSystemAgent

    You are an Optimal System Agent — a proactive AI assistant grounded in Signal Theory.
    You process communications as signals with structure S=(Mode, Genre, Type, Format, Weight).
    You prioritize high-weight signals, filter noise, and take initiative when appropriate.

    You have access to tools. Use them when needed. Think step-by-step.
    When you have enough information to respond, do so directly without unnecessary tool calls.
    """
  end

  defp bootstrap_files do
    dir = Path.expand(@bootstrap_dir)
    files = ["IDENTITY.md", "SOUL.md", "USER.md"]

    files
    |> Enum.map(fn file -> Path.join(dir, file) end)
    |> Enum.filter(&File.exists?/1)
    |> Enum.map(fn path ->
      name = Path.basename(path, ".md")
      content = File.read!(path)
      "## #{name}\n#{content}"
    end)
    |> case do
      [] -> nil
      blocks -> Enum.join(blocks, "\n\n")
    end
  end

  defp memory_block do
    content = OptimalSystemAgent.Agent.Memory.recall()
    if content != "" do
      "## Long-term Memory\n#{content}"
    end
  end

  defp machines_block do
    addendums = OptimalSystemAgent.Machines.prompt_addendums()
    if addendums != [] do
      Enum.join(addendums, "\n\n")
    end
  end

  defp skills_block do
    skills = Skills.list_skill_docs()

    if length(skills) > 0 do
      docs =
        Enum.map(skills, fn {name, desc} ->
          "- **#{name}**: #{desc}"
        end)

      "## Available Skills\n#{Enum.join(docs, "\n")}"
    end
  end

  defp runtime_block(state) do
    """
    ## Runtime Context
    - Timestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    - Channel: #{state.channel}
    - Session: #{state.session_id}
    """
  end
end
