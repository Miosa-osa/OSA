defmodule OptimalSystemAgent.Runtime.SessionResolver do
  @moduledoc """
  Resolve a user-typed session reference to exactly one real session id.

  Session ids are machine-shaped (`session-1785539672538-b5473d40b767`), so
  typing one back is unpleasant. Like git short SHAs, an unambiguous PREFIX is
  accepted — `osa resume session-1785` is enough as long as it names exactly one
  session.

  The resolution is deliberately TOTAL and EXPLICIT. Every reference lands in one
  of three buckets and nothing falls through to "start fresh":

    * `{:ok, id}`               — exactly one match (exact id wins outright)
    * `{:error, :not_found}`    — nothing matched
    * `{:error, {:ambiguous, candidates}}` — a prefix matching several sessions

  This is the whole point of the module: a mistyped id used to resolve to
  "no transcript found", which rendered as a perfectly normal empty session.
  """

  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Store.SessionTranscript

  @max_candidates 10

  @type resolution ::
          {:ok, String.t()}
          | {:error, :not_found}
          | {:error, {:ambiguous, [String.t()]}}

  @doc """
  Resolve `ref` against every session id this install knows about (persisted
  transcripts plus live/tracked runtime sessions).
  """
  @spec resolve(String.t()) :: resolution()
  def resolve(ref) when is_binary(ref), do: resolve(ref, known_session_ids())

  @doc """
  Pure resolution against an explicit id list. Split out from `resolve/1` so the
  matching rules are testable without a running registry or a populated store.
  """
  @spec resolve(String.t(), [String.t()]) :: resolution()
  def resolve(ref, known_ids) when is_binary(ref) and is_list(known_ids) do
    ref = String.trim(ref)

    cond do
      ref == "" ->
        {:error, :not_found}

      # An exact id always wins, even if it is also a prefix of a longer id.
      # Otherwise a session whose id happens to prefix another could never be
      # resumed by its full, unambiguous name.
      ref in known_ids ->
        {:ok, ref}

      true ->
        case Enum.filter(known_ids, &String.starts_with?(&1, ref)) do
          [] -> {:error, :not_found}
          [only] -> {:ok, only}
          many -> {:error, {:ambiguous, Enum.take(Enum.sort(many), @max_candidates)}}
        end
    end
  end

  @doc "Every session id this install knows about: persisted plus live/tracked."
  @spec known_session_ids() :: [String.t()]
  def known_session_ids do
    persisted =
      SessionTranscript.list_sessions(limit: 1000)
      |> Enum.map(& &1[:session_id])
      |> Enum.filter(&is_binary/1)

    Enum.uniq(persisted ++ SessionManager.list_session_ids())
  rescue
    _ -> []
  end

  @doc """
  A human-readable explanation for a failed resolution. Used verbatim as the
  API error message so the TUI can surface it without reformatting.
  """
  @spec explain(String.t(), {:ambiguous, [String.t()]} | :not_found) :: String.t()
  def explain(ref, :not_found) do
    "No session matches #{inspect(ref)}. Run `osa resume` with no id to pick from recent sessions."
  end

  def explain(ref, {:ambiguous, candidates}) do
    "#{inspect(ref)} matches #{length(candidates)} sessions: " <>
      Enum.join(candidates, ", ") <> ". Use more characters."
  end
end
