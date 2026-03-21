defmodule OptimalSystemAgent.Agent.Loop.ToolFilter do
  @moduledoc """
  Tool list filtering and budget management before LLM calls.

  Applies three layers of filtering:
  1. Signal weight gate — low-weight inputs (< 0.20) skip tools entirely to prevent
     hallucinated tool sequences for messages like "ok" or "lol".
  2. Computer-use focus mode — if the previous iteration used computer_use on a slow
     local provider, trims the tool list to CU-related tools only.
  3. Tool budget — local/slow providers (Ollama, LM Studio, llama.cpp) choke on large
     tool lists. Caps at 10, prioritising file and shell tools.
  """
  require Logger

  # Minimum signal weight required to include tools in the LLM call.
  @tool_weight_threshold 0.20

  # Priority tools kept when trimming for local providers.
  @priority_tools ~w(file_read file_write file_edit shell_execute ask_user computer_use memory_recall)

  # Local/slow provider atoms that need the tool budget cap.
  @local_providers [:ollama, :lmstudio, :llamacpp]

  @doc """
  Filter the tool list for the current state and signal weight.

  Returns a (possibly reduced) list of tool definitions to pass to the LLM.
  """
  @spec filter(list(), map()) :: list()
  def filter(tools, state) do
    tools
    |> apply_weight_gate(state)
    |> apply_computer_use_focus(state)
    |> apply_local_provider_budget(state)
  end

  # --- Private ---

  defp apply_weight_gate(tools, %{signal_weight: weight}) when is_number(weight) do
    if weight < @tool_weight_threshold do
      Logger.debug("[loop] signal_weight=#{weight} < #{@tool_weight_threshold} — skipping tools for low-weight input")
      []
    else
      tools
    end
  end

  defp apply_weight_gate(tools, _state), do: tools

  defp apply_computer_use_focus([], _state), do: []

  defp apply_computer_use_focus(tools, state) do
    last_used_cu =
      Enum.any?(state.messages, fn msg ->
        msg[:name] == "computer_use" or
          (is_map(msg[:content]) and msg[:name] == "computer_use")
      end)

    if last_used_cu and state.provider in @local_providers do
      Logger.debug("[loop] Computer-use focus mode — trimming to CU-related tools only")
      Enum.filter(tools, fn t -> t.name in ~w(computer_use file_read ask_user) end)
    else
      tools
    end
  end

  defp apply_local_provider_budget(tools, state) do
    if state.provider in @local_providers and length(tools) > 10 do
      Logger.debug("[loop] Trimming tools from #{length(tools)} to 10 for #{state.provider}")
      {priority, rest} = Enum.split_with(tools, fn t -> t.name in @priority_tools end)
      budget = max(10 - length(priority), 0)
      priority ++ Enum.take(rest, budget)
    else
      tools
    end
  end
end
