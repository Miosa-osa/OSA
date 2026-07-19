defmodule OptimalSystemAgent.Agent.CompactionSafety do
  @moduledoc """
  Compaction safety primitives — three provider-safety guarantees that wrap the
  `OptimalSystemAgent.Agent.Compactor` pipeline.

  Ported from grok-build's `xai-grok-compaction` crate (`select.rs`,
  `reminder.rs`, `sampler.rs`) and adapted to OSA's message shape.

  ## 1. Tool-pair-safe tail selection (`select.rs`)

  When compaction drops or summarizes the *older* half of the conversation, the
  split point must respect a hard invariant: an assistant message carrying tool
  requests and the `role: "tool"` result messages that satisfy those requests
  must stay on the same side of the split. Splitting between them leaves an
  **orphan tool result** at the head of the kept region — a tool result with no
  preceding tool call — which every major provider rejects with a `400`.

  `safe_split_index/2` snaps a candidate split **forward** past any contiguous
  run of tool-result messages, so the kept region always begins on a clean
  boundary (assistant/user/system message, never a dangling tool result).

  ## 2. Active-agent reminder (`reminder.rs`)

  A compaction that drops the working tail can erase the model's awareness of
  work that is *still in flight*: background shell commands, sub-agents launched
  via `delegate`, and the live TODO checklist. `active_agent_reminder/1` rebuilds
  a `<system-reminder>` block from OSA's live state
  (`Shell.BackgroundManager`, `Agent.RunStore`, `Agent.Tasks`) so the model keeps
  tracking them across the compaction boundary.

  ## 3. Degenerate-summary retry (`sampler.rs`)

  An LLM summarization call occasionally returns a near-empty or truncated
  summary ("Done.", a single header, a refusal). Replacing a large slice of
  history with such a summary is catastrophic — the detail is gone for good.
  `sample_with_retry/2` rejects a summary shorter than `min_summary_chars`
  (~500) and retries the sampler a bounded number of times before giving up
  (the caller then keeps the original messages).
  """

  require Logger

  alias OptimalSystemAgent.Shell.BackgroundManager
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.Tasks

  # Model-facing poll/cancel tool names for running sub-agents. Sourced from the
  # tool constants so a rename cannot silently point the model at a dead name.
  @poll_tool "task_resume"
  @cancel_tool "task_stop"

  # A summary shorter than this (after trimming) is treated as degenerate.
  @min_summary_chars 500

  # ---------------------------------------------------------------------------
  # 1. Tool-pair-safe tail selection (select.rs)
  # ---------------------------------------------------------------------------

  @doc """
  True when `msg` is a tool-result message (`role: "tool"`) — the kind that
  becomes an orphan if separated from its originating assistant tool call.
  """
  @spec tool_result?(map()) :: boolean()
  def tool_result?(msg) when is_map(msg) do
    safe_to_string(Map.get(msg, :role)) == "tool"
  end

  def tool_result?(_), do: false

  @doc """
  Snap a candidate split index **forward** to a tool-pair-safe boundary.

  The convention matches grok's `select.rs`: everything at
  `0..candidate` is compacted/dropped and `candidate..` is kept. If
  `messages[candidate]` is a tool result, its originating assistant call lives in
  the compacted region, so keeping it would orphan it. We advance forward past
  the whole contiguous run of tool results until the kept region starts on a
  safe message (or the list is exhausted).

  Returns an index in `0..length(messages)`. When the candidate is already safe
  it is returned unchanged.
  """
  @spec safe_split_index([map()], integer()) :: non_neg_integer()
  def safe_split_index(messages, candidate) when is_list(messages) do
    total = length(messages)
    candidate = candidate |> max(0) |> min(total)

    cond do
      candidate >= total ->
        total

      not tool_result?(Enum.at(messages, candidate)) ->
        candidate

      true ->
        snap_forward(messages, candidate, total)
    end
  end

  defp snap_forward(messages, idx, total) do
    if idx < total and tool_result?(Enum.at(messages, idx)) do
      snap_forward(messages, idx + 1, total)
    else
      idx
    end
  end

  @doc """
  Faithful port of grok's `select_turns_to_compact`: walk the list backward
  accumulating per-message token counts until the newest-kept region reaches
  `target_tokens`, then snap the resulting split forward to a tool-pair-safe
  boundary.

  `token_fun` maps a message to its token count. Returns `{:ok, split_idx}` where
  `0..split_idx` is the compactable region, or `:none` when nothing worth
  compacting remains (whole list fits, or the compactable region snapped away to
  nothing).
  """
  @spec select_tail([map()], non_neg_integer(), (map() -> non_neg_integer())) ::
          {:ok, non_neg_integer()} | :none
  def select_tail(messages, target_tokens, token_fun)
      when is_list(messages) and is_function(token_fun, 1) do
    total = length(messages)

    if total == 0 do
      :none
    else
      counts = Enum.map(messages, token_fun)
      naive = backward_split(counts, target_tokens, total)

      cond do
        naive == 0 ->
          :none

        true ->
          safe = safe_split_index(messages, naive)
          if safe >= total, do: :none, else: {:ok, safe}
      end
    end
  end

  # Highest split_idx such that sum(counts[split_idx..]) <= target_tokens.
  defp backward_split(counts, target_tokens, total) do
    counts
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while({0, total}, fn {count, i}, {kept, _split} ->
      if kept + count > target_tokens do
        {:halt, {kept, i + 1}}
      else
        {:cont, {kept + count, i}}
      end
    end)
    |> elem(1)
  end

  # ---------------------------------------------------------------------------
  # 2. Active-agent reminder (reminder.rs)
  # ---------------------------------------------------------------------------

  @doc """
  Build the post-compaction active-agent `<system-reminder>` string from live
  OSA state, or `nil` when nothing is still active.

  Sections, in order (empty sections omitted):

    * `## Running Background Tasks` — live `Shell.BackgroundManager` commands
    * `## TODO List`               — actionable `Agent.Tasks` items
    * `## Running Subagents`        — `Agent.RunStore` runs still `:running`
  """
  @spec active_agent_reminder(String.t() | nil) :: String.t() | nil
  def active_agent_reminder(session_id) do
    sections =
      [
        section_background_tasks(session_id),
        section_todo_list(session_id),
        section_running_subagents(session_id)
      ]
      |> Enum.reject(&is_nil/1)

    wrap_system_reminder(sections)
  rescue
    e ->
      Logger.debug("[compaction_safety] active_agent_reminder failed: #{inspect(e)}")
      nil
  end

  @doc """
  Same as `active_agent_reminder/1` but wrapped as a `role: "system"` message
  map ready to append to the compacted message list. Returns `nil` when there is
  nothing active to remind about.
  """
  @spec build_reminder_message(String.t() | nil) :: map() | nil
  def build_reminder_message(session_id) do
    case active_agent_reminder(session_id) do
      nil -> nil
      body -> %{role: "system", content: body}
    end
  end

  defp section_background_tasks(session_id) do
    tasks =
      try do
        BackgroundManager.list()
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    running =
      tasks
      |> Enum.filter(fn t -> Map.get(t, :status) == :running end)
      |> then(fn list ->
        if is_binary(session_id) do
          # Prefer this session's tasks, but keep session-less entries too.
          Enum.filter(list, fn t ->
            sid = Map.get(t, :session_id)
            is_nil(sid) or sid == session_id
          end)
        else
          list
        end
      end)

    case running do
      [] ->
        nil

      list ->
        lines =
          Enum.map(list, fn t ->
            id = Map.get(t, :id, "?")
            command = one_line(safe_to_string(Map.get(t, :command, "")), 120)
            "- \"#{id}\": `#{command}` (running)"
          end)

        "## Running Background Tasks\n" <>
          "These tasks are still running:\n" <> Enum.join(lines, "\n")
    end
  end

  defp section_todo_list(session_id) when is_binary(session_id) do
    tasks =
      try do
        Tasks.get_tasks(session_id)
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    tasks = if is_list(tasks), do: tasks, else: []

    active =
      Enum.filter(tasks, fn t -> Map.get(t, :status) in [:pending, :in_progress] end)

    case active do
      [] ->
        nil

      list ->
        lines =
          Enum.map(list, fn t ->
            id = Map.get(t, :id, "?")
            title = one_line(safe_to_string(Map.get(t, :title) || Map.get(t, :subject) || ""), 200)
            "- #{status_tag(Map.get(t, :status))} #{id}: #{title}"
          end)

        completed = Enum.count(tasks, fn t -> Map.get(t, :status) == :completed end)
        cancelled = Enum.count(tasks, fn t -> Map.get(t, :status) in [:cancelled, :failed] end)

        trailer =
          case {completed, cancelled} do
            {0, 0} -> ""
            {c, 0} -> "\n(#{c} completed)"
            {0, k} -> "\n(#{k} cancelled)"
            {c, k} -> "\n(#{c} completed, #{k} cancelled)"
          end

        "## TODO List\n" <>
          "This is your task list from before the conversation was compacted — it is still " <>
          "active. Keep working through the items below and update their status as you make " <>
          "progress:\n" <> Enum.join(lines, "\n") <> trailer
    end
  end

  defp section_todo_list(_), do: nil

  defp section_running_subagents(session_id) do
    runs =
      try do
        RunStore.list(status: :running)
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    runs = if is_list(runs), do: runs, else: []

    runs =
      if is_binary(session_id) do
        Enum.filter(runs, fn r ->
          parent = Map.get(r, :parent_session_id)
          is_nil(parent) or parent == session_id
        end)
      else
        runs
      end

    case runs do
      [] ->
        nil

      list ->
        lines = Enum.map(list, &format_subagent_line/1)

        "## Running Subagents\n" <>
          "These subagents were launched before this compaction and are still running. " <>
          "Use `#{@poll_tool}` with the subagent_id to check their status or retrieve results. " <>
          "Use `#{@cancel_tool}` with the subagent_id to cancel a subagent.\n" <>
          Enum.join(lines, "\n")
    end
  end

  defp format_subagent_line(run) do
    id = Map.get(run, :agent_id, "?")
    role = safe_to_string(Map.get(run, :role, ""))
    task = one_line(safe_to_string(Map.get(run, :task, "")), 160)
    elapsed = elapsed_secs(Map.get(run, :started_at))

    head = "subagent_id: `#{id}`"
    head = if role == "", do: head, else: head <> ", type: `#{role}`"
    head = if task == "", do: head, else: head <> ", task: \"#{task}\""

    "- #{head} (running for #{elapsed}s)"
  end

  defp elapsed_secs(%DateTime{} = started_at) do
    DateTime.utc_now() |> DateTime.diff(started_at) |> max(0)
  end

  defp elapsed_secs(_), do: 0

  defp status_tag(:in_progress), do: "[in_progress]"
  defp status_tag(:pending), do: "[pending]"
  defp status_tag(_), do: "[pending]"

  @doc """
  Wrap non-empty sections in a single `<system-reminder>` block, joined by blank
  lines. Returns `nil` when every section is blank.
  """
  @spec wrap_system_reminder([String.t()]) :: String.t() | nil
  def wrap_system_reminder(sections) do
    body =
      sections
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.join("\n\n")

    if body == "" do
      nil
    else
      "<system-reminder>\n#{body}\n</system-reminder>"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Degenerate-summary retry (sampler.rs)
  # ---------------------------------------------------------------------------

  @doc "Minimum acceptable summary length (chars, after trimming)."
  @spec min_summary_chars() :: non_neg_integer()
  def min_summary_chars, do: @min_summary_chars

  @doc """
  True when `summary` is too short to be a trustworthy replacement for a slice
  of conversation history (empty, whitespace, or `< min_summary_chars`).
  """
  @spec degenerate_summary?(term()) :: boolean()
  def degenerate_summary?(summary) when is_binary(summary) do
    String.length(String.trim(summary)) < @min_summary_chars
  end

  def degenerate_summary?(_), do: true

  @doc """
  Run `sampler` (a 0-arity fun returning `{:ok, summary} | {:error, reason}`),
  rejecting and retrying degenerate summaries.

  Options:
    * `:max_attempts` — total attempts including the first (default 2)
    * `:min_chars`    — override the degenerate threshold

  Returns the first non-degenerate `{:ok, summary}`. If every attempt is
  degenerate it returns `{:error, {:degenerate_summary, last}}`; a sampler
  `{:error, reason}` short-circuits immediately (it is not a length problem).
  """
  @spec sample_with_retry((-> {:ok, binary()} | {:error, term()}), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def sample_with_retry(sampler, opts \\ []) when is_function(sampler, 0) do
    max_attempts = Keyword.get(opts, :max_attempts, 2)
    min_chars = Keyword.get(opts, :min_chars, @min_summary_chars)
    do_sample(sampler, max_attempts, min_chars, 1, "")
  end

  defp do_sample(_sampler, max_attempts, _min, attempt, last) when attempt > max_attempts do
    {:error, {:degenerate_summary, last}}
  end

  defp do_sample(sampler, max_attempts, min_chars, attempt, _last) do
    case sampler.() do
      {:ok, summary} when is_binary(summary) ->
        if String.length(String.trim(summary)) >= min_chars do
          {:ok, summary}
        else
          Logger.debug(
            "[compaction_safety] degenerate summary on attempt #{attempt} " <>
              "(#{String.length(String.trim(summary))} < #{min_chars} chars) — retrying"
          )

          do_sample(sampler, max_attempts, min_chars, attempt + 1, summary)
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_sampler_result, other}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp one_line(text, max) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> then(fn s ->
      if String.length(s) > max, do: String.slice(s, 0, max) <> "…", else: s
    end)
  end

  defp safe_to_string(val), do: OptimalSystemAgent.Utils.Text.safe_to_string(val)
end
