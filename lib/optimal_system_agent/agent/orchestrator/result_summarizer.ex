defmodule OptimalSystemAgent.Agent.Orchestrator.ResultSummarizer do
  @moduledoc """
  Turns a finished subagent's structured result + transcript into a concise,
  natural-language synthesis for the parent orchestrator.

  This replaces the fixed `RunStore.format_result/1` key/value template as the
  *return value* of a delegation. The parent LLM reads prose far better than a
  metadata block, so we lead with the child's own final assistant message (its
  self-authored conclusion) and append only a compact facts line when there is
  concrete work (files changed / commands run) worth surfacing.

  `RunStore.format_result/1` is still used verbatim for the on-disk transcript —
  this module only shapes what flows back to the orchestrator's context.
  """

  @max_summary_chars 4_000

  @doc """
  Build a natural-language synthesis of a completed subagent run.

  Prefers, in order:
    1. The structured `:summary` (already the child's final assistant message).
    2. The last assistant message in the transcript.
    3. A minimal status line.

  A short "facts" footer (files / commands / tools) is appended only when it
  adds signal.
  """
  @spec summarize(map(), [map()]) :: String.t()
  def summarize(structured, messages \\ []) when is_map(structured) do
    role = to_string(Map.get(structured, :role, "agent"))
    status = Map.get(structured, :status, :completed)

    body =
      structured
      |> Map.get(:summary, "")
      |> blank_to_nil()
      |> Kernel.||(final_assistant_message(messages))
      |> blank_to_nil()
      |> Kernel.||("#{role} finished with status #{status} (no textual output).")
      |> String.trim()
      |> truncate(@max_summary_chars)

    header = "#{role} subagent #{status}."

    [header, body, facts_footer(structured)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # --- Private ---

  defp final_assistant_message(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(nil, fn msg ->
      role = Map.get(msg, :role) || Map.get(msg, "role")
      content = Map.get(msg, :content) || Map.get(msg, "content")

      if role == "assistant" and is_binary(content) and String.trim(content) != "" do
        content
      else
        nil
      end
    end)
  end

  defp final_assistant_message(_), do: nil

  defp facts_footer(structured) do
    files = Map.get(structured, :files_changed, []) |> List.wrap()
    commands = Map.get(structured, :commands_run, []) |> List.wrap()
    tools = Map.get(structured, :tool_count, 0)

    parts =
      []
      |> maybe_part(files != [], "Files changed: #{Enum.join(files, ", ")}")
      |> maybe_part(commands != [], "Commands run: #{Enum.join(commands, "; ")}")
      |> maybe_part(is_integer(tools) and tools > 0, "Tools used: #{tools}")

    case parts do
      [] -> nil
      list -> list |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp maybe_part(acc, true, str), do: [str | acc]
  defp maybe_part(acc, _false, _str), do: acc

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(str) when is_binary(str) do
    if String.trim(str) == "", do: nil, else: str
  end

  defp blank_to_nil(other), do: other

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "\n… (truncated)"
    else
      str
    end
  end

  defp truncate(str, _), do: str
end
