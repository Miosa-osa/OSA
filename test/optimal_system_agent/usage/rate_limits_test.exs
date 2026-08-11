defmodule OptimalSystemAgent.Usage.RateLimitsTest do
  @moduledoc """
  Every value here is a measurement with an age, and `/usage` renders that age.

  So the age has to be the age of the READING, not of the bookkeeping: if a
  reading is timestamped when its cast happens to be handled, a slow earlier
  response that lands after a newer one both replaces a correct number with a
  superseded one and presents it as freshly observed.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Usage.RateLimits

  setup do
    case Process.whereis(RateLimits) do
      nil -> start_supervised!(RateLimits)
      _ -> :ok
    end

    :ok
  end

  defp provider, do: "test_provider_#{System.unique_integer([:positive])}"

  test "an observation keeps the time it was taken, not the time it was handled" do
    id = provider()
    taken_at = System.system_time(:second) - 600

    RateLimits.record(id, %{used_percent: 42.0, observed_at: taken_at})

    assert %{used_percent: 42.0, observed_at: ^taken_at} = RateLimits.get(id)
  end

  test "a late-arriving older reading does not overwrite a newer one" do
    id = provider()
    now = System.system_time(:second)

    RateLimits.record(id, %{used_percent: 71.0, limit_name: "weekly", observed_at: now})

    # The same window as it looked an hour ago, arriving late (slow response,
    # or two in-flight requests completing out of order).
    RateLimits.record(id, %{used_percent: 12.0, limit_name: "weekly", observed_at: now - 3_600})

    observation = RateLimits.get(id)

    assert observation.used_percent == 71.0,
           "a stale reading replaced a newer one"

    assert observation.observed_at == now,
           "a stale reading was re-dated as if just observed"
  end

  test "a newer reading does replace an older one" do
    id = provider()
    now = System.system_time(:second)

    RateLimits.record(id, %{used_percent: 12.0, observed_at: now - 3_600})
    RateLimits.record(id, %{used_percent: 71.0, observed_at: now})

    assert %{used_percent: 71.0, observed_at: ^now} = RateLimits.get(id)
  end

  test "an unobserved provider is nil, never zero" do
    assert RateLimits.get(provider()) == nil
  end
end
