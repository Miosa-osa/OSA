defmodule OptimalSystemAgent.Agent.Hooks.Matcher do
  @moduledoc """
  Hook matcher engine — port of Claude Code's `matchesPattern`
  (`utils/hooks.ts`).

  Matcher semantics:

    * `nil`, `""` or `"*"` — matches everything
    * `"Write"` — exact match
    * `"Write|Edit"` — pipe-separated exact matches
    * anything else — treated as a regex (an invalid regex never matches)

  A `nil` match QUERY means the event has no matcher dimension (Stop,
  SessionEnd, …) — matchers are ignored for those events, mirroring CC.
  """

  @simple ~r/^[a-zA-Z0-9_|]+$/

  @spec matches?(String.t() | nil, String.t() | nil) :: boolean()
  def matches?(matcher, _query) when matcher in [nil, "", "*"], do: true
  def matches?(_matcher, nil), do: true

  def matches?(matcher, query) when is_binary(matcher) and is_binary(query) do
    if Regex.match?(@simple, matcher) do
      matcher
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.member?(query)
    else
      case Regex.compile(matcher) do
        {:ok, re} -> Regex.match?(re, query)
        {:error, _} -> false
      end
    end
  end

  def matches?(_, _), do: false
end
