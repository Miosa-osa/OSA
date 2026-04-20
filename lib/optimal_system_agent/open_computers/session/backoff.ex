defmodule OptimalSystemAgent.OpenComputers.Session.Backoff do
  @moduledoc """
  Exponential backoff with jitter for reconnect scheduling.

    * Initial delay 1 s
    * Doubles each attempt, capped at 60 s
    * ±200 ms uniform jitter to decorrelate reconnect thundering-herds
  """

  @initial_ms 1_000
  @max_ms 60_000
  @jitter_ms 200

  @spec initial() :: pos_integer()
  def initial, do: @initial_ms

  @spec max() :: pos_integer()
  def max, do: @max_ms

  @spec next(pos_integer()) :: pos_integer()
  def next(current) when is_integer(current) and current > 0 do
    min(current * 2, @max_ms)
  end

  @spec with_jitter(pos_integer()) :: pos_integer()
  def with_jitter(base_ms), do: base_ms + :rand.uniform(@jitter_ms)
end
