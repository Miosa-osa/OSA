defmodule OptimalSystemAgent.Agent.Loop.TransientNotes do
  @moduledoc """
  Notes the loop adds to the transcript for the NEXT step only, and the rule
  that keeps them from accumulating: a new note of a kind replaces the
  previous note of that kind, so at most one of each is ever live.

  These are `role: "system"` messages OSA writes itself, each with a fixed
  header owned here (`header/1`):

    * `:advisor`          - `Advisor.frame/1`, after an advisor consult
    * `:output_contract`  - `Signal.OutputContract.directive_for/1`, every turn
    * `:no_progress`      - the homeostat's reorientation note
    * `:ledger_recap`     - the progress-ledger recap, every turn
    * `:screen_question`  - the "user is asking about the screen" directive
    * `:task_list`        - the "create a task list" directive
    * `:team_dispatch`    - the "team dispatch recommended" directive

  They used to be appended and never removed. MEASURED on a resumed
  `deepseek-v4.1-flash:cloud` session: 363 messages, 153 of them notes (91
  advisor recommendations, 15 output contracts, 9 progress nudges), 164k of
  the transcript's 329k characters. The checkpoint persisted every one and a
  resume restored every one, so the first request after the resume carried
  151k input tokens, about half of them stale notes.

  Removing the previous note shifts the request prefix from that note
  onward, which costs prompt-cache reads on providers that cache. The note
  replaced is the previous one of its kind, so it sits within the last turn
  or so; the re-cached span is that tail, against a note that otherwise
  rides in every request for the rest of the session.
  """

  @type kind ::
          :advisor
          | :output_contract
          | :no_progress
          | :ledger_recap
          | :screen_question
          | :task_list
          | :team_dispatch

  @headers %{
    advisor: "[ADVISOR RECOMMENDATION",
    output_contract: "[Output contract",
    ledger_recap: "[System: Progress ledger recap]",
    screen_question: "[System: The user is asking about what is visible on the screen",
    task_list: "[System: This task has multiple steps.",
    team_dispatch: "[System: TEAM DISPATCH recommended."
  }

  # The homeostat's header carries a count ("[System: 6 tool calls with no
  # measured progress"), so it is matched by pattern rather than prefix.
  @no_progress ~r/\A\[System: \d+ tool calls with no measured progress/

  @doc "The fixed header a note of `kind` starts with (`:no_progress` has a count in it)."
  @spec header(kind()) :: String.t()
  def header(:no_progress), do: "[System: "
  def header(kind), do: Map.fetch!(@headers, kind)

  @doc "The transient-note kind of `message`, or `nil` for any other message."
  @spec kind_of(map()) :: kind() | nil
  def kind_of(message) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")

    if to_string(role) == "system" and is_binary(content) do
      Enum.find_value(@headers, fn {kind, prefix} ->
        if String.starts_with?(content, prefix), do: kind
      end) || if(Regex.match?(@no_progress, content), do: :no_progress)
    end
  end

  def kind_of(_), do: nil

  @doc "Append `new` messages to `messages`; each new note replaces earlier notes of its kind."
  @spec append([map()], [map()]) :: [map()]
  def append(messages, new) when is_list(messages) and is_list(new) do
    superseded = new |> Enum.map(&kind_of/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

    kept =
      if MapSet.size(superseded) == 0,
        do: messages,
        else: Enum.reject(messages, &(kind_of(&1) in superseded))

    kept ++ new
  end

  @doc """
  Keep only the last note of each kind. For transcripts written before notes
  were superseded: a restored checkpoint can carry hundreds of them.
  """
  @spec prune([map()]) :: [map()]
  def prune(messages) when is_list(messages) do
    {kept, _seen} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new()}, fn msg, {acc, seen} ->
        case kind_of(msg) do
          nil ->
            {[msg | acc], seen}

          kind ->
            if MapSet.member?(seen, kind),
              do: {acc, seen},
              else: {[msg | acc], MapSet.put(seen, kind)}
        end
      end)

    kept
  end
end
