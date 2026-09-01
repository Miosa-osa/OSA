defmodule OptimalSystemAgent.Utils.Duration do
  @moduledoc """
  Human-readable durations for user-facing text. Raw `#{"#{}"}ms` (e.g.
  `298723ms`) is unreadable in a notification or the dashboard; this renders it
  as `4m 59s`.
  """

  @doc """
  Format a millisecond duration as compact human-readable text.

      iex> humanize(450)
      "450ms"
      iex> humanize(4_300)
      "4.3s"
      iex> humanize(298_723)
      "4m 59s"
      iex> humanize(3_930_000)
      "1h 5m"
  """
  @spec humanize(integer() | nil) :: String.t()
  def humanize(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms < 1_000 ->
        "#{ms}ms"

      ms < 60_000 ->
        "#{Float.round(ms / 1_000, 1)}s"

      ms < 3_600_000 ->
        s = div(ms, 1_000)
        "#{div(s, 60)}m #{rem(s, 60)}s"

      true ->
        m = div(ms, 60_000)
        "#{div(m, 60)}h #{rem(m, 60)}m"
    end
  end

  def humanize(_), do: ""
end
