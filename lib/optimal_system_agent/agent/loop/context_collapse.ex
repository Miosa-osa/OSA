defmodule OptimalSystemAgent.Agent.Loop.ContextCollapse do
  @moduledoc """
  Context collapse — graceful recovery from context overflow (413) errors.

  When the LLM API returns a context-too-large error, progressively
  withholds the largest tool results and retries. This avoids losing
  the entire conversation on overflow.
  """
  require Logger

  @max_attempts 3

  @doc """
  Check if an error indicates context overflow.
  """
  def context_overflow_error?({:error, reason}) when is_binary(reason) do
    reason_down = String.downcase(reason)

    Enum.any?(
      [
        "prompt is too long",
        "context_length_exceeded",
        "maximum context length",
        "context window exceeded",
        "token limit",
        "too many tokens",
        "request too large",
        "413"
      ],
      fn pattern -> String.contains?(reason_down, pattern) end
    )
  end

  def context_overflow_error?(_), do: false

  @doc """
  Attempt to collapse context by withholding large tool results.

  Returns `{:ok, collapsed_messages}` or `{:error, :cannot_collapse}`.
  Each attempt withholds progressively more results.
  """
  def collapse(messages, attempt \\ 1)

  def collapse(_messages, attempt) when attempt > @max_attempts do
    {:error, :cannot_collapse}
  end

  def collapse(messages, attempt) do
    # Find all tool result messages with their sizes, sorted largest first
    tool_results =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _idx} ->
        role = Map.get(msg, :role) || Map.get(msg, "role")
        role == "tool"
      end)
      |> Enum.map(fn {msg, idx} ->
        content = to_string(Map.get(msg, :content) || Map.get(msg, "content") || "")
        {idx, byte_size(content), msg}
      end)
      |> Enum.sort_by(fn {_idx, size, _msg} -> size end, :desc)

    # Withhold the N largest tool results (N = attempt count)
    to_withhold = Enum.take(tool_results, attempt)

    if to_withhold == [] do
      {:error, :cannot_collapse}
    else
      withhold_indices = MapSet.new(Enum.map(to_withhold, fn {idx, _, _} -> idx end))

      total_saved =
        to_withhold
        |> Enum.map(fn {_, size, _} -> size end)
        |> Enum.sum()

      collapsed =
        messages
        |> Enum.with_index()
        |> Enum.map(fn {msg, idx} ->
          if idx in withhold_indices do
            tool_name = Map.get(msg, :name) || Map.get(msg, :tool_call_id) || "tool"
            original_size = byte_size(to_string(Map.get(msg, :content) || ""))

            Map.put(
              msg,
              :content,
              "[Tool result withheld — #{tool_name}, #{original_size} bytes. " <>
                "Context window overflow recovery, attempt #{attempt}/#{@max_attempts}]"
            )
          else
            msg
          end
        end)

      Logger.info(
        "[context_collapse] Attempt #{attempt}: withheld #{length(to_withhold)} tool results " <>
          "(saved ~#{div(total_saved, 1024)}KB)"
      )

      # PostCompact hook — overflow-recovery collapse is a form of compaction.
      fire_compact_hook(:post_compact, %{
        phase: :post,
        strategy: :overflow_collapse,
        attempt: attempt,
        tokens_saved: total_saved,
        withheld: length(to_withhold)
      })

      {:ok, collapsed}
    end
  end

  # Fire a compaction lifecycle hook. Fire-and-forget; never blocks recovery.
  defp fire_compact_hook(event, payload) do
    OptimalSystemAgent.Agent.Hooks.run_async(event, payload)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
