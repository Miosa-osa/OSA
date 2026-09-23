defmodule OptimalSystemAgent.Agent.Loop.ContextCollapse do
  @moduledoc """
  Context collapse — graceful recovery from context overflow (413) errors.

  When the LLM API returns a context-too-large error, progressively
  withholds the largest tool results and retries. This avoids losing
  the entire conversation on overflow.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Utils.Text

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
        # A tool result CAN be a block LIST (an image file read), on which
        # `to_string/1` raises — so overflow recovery must extract the text.
        content =
          OptimalSystemAgent.Utils.Text.content_text(
            Map.get(msg, :content) || Map.get(msg, "content")
          )

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

            original_size =
              byte_size(OptimalSystemAgent.Utils.Text.content_text(Map.get(msg, :content)))

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

  # The single latest user message has to be bigger than HALF the resolved
  # window before this is trusted as the reason a turn cannot fit, rather
  # than reached for as a first resort.
  @oversized_fraction 0.5
  @head_bytes 20_000
  @tail_bytes 10_000

  @doc """
  Last-resort overflow recovery: the LATEST user message is, on its own,
  larger than half the model's context window.

  `collapse/2` only ever withholds TOOL results, and the compactor's
  hot-zone selection deliberately preserves the single most-recent turn
  VERBATIM no matter how large it is — by design, so a turn is never
  silently dropped (`Agent.Compactor.select_turn_tail/2`'s `:none` branch).
  That means an oversized *user* message survives every collapse and
  compaction attempt unchanged, and the turn fails as a context overflow
  forever. This is the one thing that actually has to shrink.

  A head+tail excerpt (mirroring `Loop.ToolResultStorage`'s preview
  convention) stays inline; the untouched original is written to disk so the
  model can retrieve every byte with `file_read`, and the inline excerpt says
  so explicitly.

  Returns `{:ok, messages}` with the trim applied, or `:error` when there is
  no oversized latest user message to trim — the caller's overflow has a
  different cause and this recovery does not apply.
  """
  @spec trim_oversized_latest_message([map()], term(), String.t() | nil) ::
          {:ok, [map()]} | :error
  def trim_oversized_latest_message(messages, context_window, session_id \\ nil) do
    window =
      case Compactor.resolve_window(context_window) do
        {:ok, n} -> n
        :unknown -> CompactionThresholds.fallback_window()
      end

    threshold = trunc(window * @oversized_fraction)

    with idx when is_integer(idx) <- last_real_user_index(messages),
         msg <- Enum.at(messages, idx),
         text <- Text.content_text(Map.get(msg, :content) || Map.get(msg, "content")),
         true <- is_binary(text) and text != "",
         tokens <- Compactor.estimate_tokens(text),
         true <- tokens > threshold do
      path = persist_full_text(text, session_id)

      Logger.warning(
        "[context_collapse] latest user message alone is ~#{tokens} tokens " <>
          "(> half of a #{window}-token window) — trimming to a head+tail excerpt" <>
          if(path, do: " (full text saved to #{path})", else: " (could not persist full text)")
      )

      trimmed_content = build_trim_note(text, path)
      new_msg = Map.put(msg, :content, trimmed_content)

      {:ok, List.replace_at(messages, idx, new_msg)}
    else
      _ -> :error
    end
  end

  # The last non-scaffold `role: "user"` message — the user's own latest
  # input, never a synthetic interrupt/continuation marker `ReactLoop` injects
  # (those carry `scaffold: true` and are never the oversized culprit).
  defp last_real_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} ->
      role = Map.get(msg, :role) || Map.get(msg, "role")
      scaffold? = (Map.get(msg, :scaffold) || Map.get(msg, "scaffold")) == true
      if role == "user" and not scaffold?, do: idx
    end)
  end

  defp persist_full_text(text, session_id) do
    dir = Path.join(ConfigFile.config_dir(), "tool-results")
    File.mkdir_p!(dir)

    # Named like `Loop.ToolResultStorage`'s `<session>_*` files so the same
    # per-session `cleanup/1` glob and the age-based orphan sweep pick this up
    # too — no separate lifecycle to maintain.
    filename = "#{sanitize_component(session_id)}_oversized-message_#{:erlang.phash2(text)}.txt"
    path = Path.join(dir, filename)

    case File.write(path, text) do
      :ok -> path
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  end

  defp build_trim_note(text, path) do
    total = byte_size(text)
    head = Text.utf8_head(text, @head_bytes)
    tail = Text.utf8_tail(text, @tail_bytes)
    omitted = max(total - byte_size(head) - byte_size(tail), 0)

    location_note =
      if path do
        "The full, untouched message (#{total} bytes) was saved to #{path} — read it with " <>
          "file_read (use offset/limit to page through it) if you need the omitted middle."
      else
        "The full message could not be saved to disk, so the omitted middle (#{omitted} " <>
          "bytes) is unavailable."
      end

    "[This message was #{total} bytes — on its own, larger than half the model's context " <>
      "window, so it could not be sent in full. Showing the first #{byte_size(head)} and last " <>
      "#{byte_size(tail)} bytes below. #{location_note}]\n\n#{head}\n\n… #{omitted} bytes " <>
      "omitted …\n\n#{tail}"
  end

  defp sanitize_component(nil), do: "nosession"

  defp sanitize_component(value) do
    case Regex.replace(~r/[^a-zA-Z0-9_\-]/, to_string(value), "_") do
      "" -> "nosession"
      s -> s
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
