defmodule OptimalSystemAgent.Agent.Orchestrator.ResultSummarizer do
  @moduledoc """
  Turns a finished subagent's structured result + transcript into the value the
  parent orchestrator actually receives from a `delegate` call.

  ## The contract: delegation RETURNS THE WORK

  The whole point of delegating is to get the child's findings back. The parent
  LLM must be able to act on this string alone, without reading any file and
  without re-doing the child's work. Two rules follow, and both are load-bearing:

    1. **The child's own words lead.** The child's final assistant message is the
       FIRST thing in the returned string — no status header in front of it.
       This matters twice over: the parent reads the report immediately, and the
       Rust `DelegateRenderer` shows the result's *first line* in its collapsed
       tool cell, so the user sees a real finding instead of a status notice.
       (Regression guarded: a header-first layout previously made every delegate
       cell read `"<role> subagent completed."` and nothing else.)

    2. **Never return a content-free result.** If the child produced no final
       text, we do not shrug and emit `"(no textual output)"` — that reads to the
       parent as "the work is lost, go do it yourself". Instead we RECOVER: the
       last substantive assistant text anywhere in the transcript, then a digest
       of what the child actually did, and always the on-disk transcript path so
       the parent can read the rest with `file_read`. The recovery block is
       explicitly marked so the parent never mistakes it for a real report.

  Status/facts (role, status, files, commands, tools) move to a compact trailer.
  They are metadata about the work, not the work.

  Truncation is explicit and recoverable: oversized reports are cut with a marker
  that names the transcript path holding the full text — the default is never to
  silently drop the body.

  `RunStore.format_result/1` is still used verbatim for the on-disk transcript —
  this module only shapes what flows back to the orchestrator's context.
  """

  # Matches `Delegate.Tool.max_result_size_chars/0` so a report is not cut here
  # only to fit under a larger downstream budget. The child's report is the
  # single most valuable tool result the parent gets; 4k was cutting real work.
  @max_summary_chars 10_000

  # How many recent tool names to list when reconstructing what a silent child did.
  @max_digest_tools 12

  @doc """
  Build the parent-facing return value for a completed subagent run.

  Leads with the child's own final output. Falls back, in order, to:

    1. The structured `:summary` (the child's final assistant message).
    2. The last non-blank assistant message anywhere in the transcript.
    3. An explicitly-marked recovery block (activity digest + transcript path).

  A compact status/facts trailer is appended.
  """
  @spec summarize(map(), [map()]) :: String.t()
  def summarize(structured, messages \\ []) when is_map(structured) do
    role = to_string(Map.get(structured, :role, "agent"))
    status = Map.get(structured, :status, :completed)

    lead =
      case child_output(structured, messages) do
        {:ok, text} -> truncate(text, @max_summary_chars, structured)
        :none -> recovery_block(role, status, structured, messages)
      end

    [lead, status_trailer(role, status, structured)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # --- Child output ------------------------------------------------------

  # The child's actual words, or :none if it finished without producing any.
  @spec child_output(map(), [map()]) :: {:ok, String.t()} | :none
  defp child_output(structured, messages) do
    text =
      structured
      |> Map.get(:summary, "")
      |> blank_to_nil()
      |> Kernel.||(final_assistant_message(messages))
      |> blank_to_nil()

    case text do
      nil -> :none
      str -> {:ok, String.trim(str)}
    end
  end

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

  # --- Recovery (child produced no final text) ---------------------------

  # A child that ran for minutes and returned nothing must not be reported as an
  # empty success. Surface WHAT it did and WHERE the full record is, marked so
  # the parent treats it as salvage rather than as the child's conclusion.
  defp recovery_block(role, status, structured, messages) do
    lines =
      [
        "**NO FINAL REPORT** — the #{role} subagent finished (status: #{status}) " <>
          "without producing a closing message. Recovered context below; " <>
          "treat it as partial, not as the subagent's conclusion."
      ]
      |> maybe_line(activity_digest(messages))
      |> maybe_line(transcript_pointer(structured))

    lines |> Enum.reverse() |> Enum.join("\n\n")
  end

  # What the child actually did, reconstructed from its tool calls. This is the
  # difference between "nothing came back" and "it grepped X, read Y, ran Z".
  defp activity_digest(messages) when is_list(messages) do
    names =
      messages
      |> Enum.flat_map(&tool_names/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    case names do
      [] ->
        nil

      list ->
        recent = list |> Enum.reverse() |> Enum.take(@max_digest_tools) |> Enum.reverse()
        "Work performed (#{length(list)} tool call(s)): " <> Enum.join(recent, " → ")
    end
  end

  defp activity_digest(_), do: nil

  defp tool_names(msg) when is_map(msg) do
    case Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") do
      calls when is_list(calls) ->
        Enum.map(calls, fn call ->
          cond do
            is_map(call) -> to_string(Map.get(call, :name) || Map.get(call, "name") || "")
            true -> ""
          end
        end)

      _ ->
        []
    end
  end

  defp tool_names(_), do: []

  defp transcript_pointer(structured) do
    case Map.get(structured, :transcript_path) do
      path when is_binary(path) and path != "" and path != "unavailable" ->
        "Full transcript (read it with `file_read` if you need the detail): #{path}"

      _ ->
        nil
    end
  end

  # --- Status / facts trailer --------------------------------------------

  defp status_trailer(role, status, structured) do
    facts =
      []
      |> maybe_part(true, "#{role} subagent #{status}")
      |> maybe_part_list(Map.get(structured, :files_changed, []), "files changed")
      |> maybe_part_list(Map.get(structured, :commands_run, []), "commands run")
      |> maybe_tools(Map.get(structured, :tool_count, 0))

    "— " <> (facts |> Enum.reverse() |> Enum.join(" · "))
  end

  defp maybe_part(acc, true, str), do: [str | acc]
  defp maybe_part(acc, _false, _str), do: acc

  defp maybe_part_list(acc, list, label) do
    case List.wrap(list) do
      [] -> acc
      items -> ["#{label}: #{Enum.join(items, ", ")}" | acc]
    end
  end

  defp maybe_tools(acc, count) when is_integer(count) and count > 0,
    do: ["#{count} tool call(s)" | acc]

  defp maybe_tools(acc, _), do: acc

  defp maybe_line(acc, nil), do: acc
  defp maybe_line(acc, ""), do: acc
  defp maybe_line(acc, line), do: [line | acc]

  # --- Helpers -----------------------------------------------------------

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(str) when is_binary(str) do
    if String.trim(str) == "", do: nil, else: str
  end

  defp blank_to_nil(other), do: other

  # Truncation names where the rest lives, so an oversized report degrades to
  # "here is most of it + how to get the rest" rather than to silent loss.
  defp truncate(str, max, structured) when is_binary(str) do
    if String.length(str) > max do
      tail =
        case transcript_pointer(structured) do
          nil -> ""
          pointer -> " " <> pointer
        end

      String.slice(str, 0, max) <>
        "\n\n… (truncated at #{max} chars — this report was longer.#{tail})"
    else
      str
    end
  end

  defp truncate(str, _max, _structured), do: str
end
