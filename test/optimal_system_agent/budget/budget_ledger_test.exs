defmodule OptimalSystemAgent.Budget.LedgerTest do
  @moduledoc """
  Budget-ledger accounting correctness.

    * `:record_cost` accumulated WITHOUT a lazy reset, so spend recorded between
      midnight and the first `check_budget`/`get_status` landed in the previous
      day's bucket — which that first read then zeroed. Real post-midnight spend
      was erased.
    * The call count was `length(entries)` over a list capped at 10 000, so it
      froze there.
    * `record_priced_cost/5` keeps `Agent.Pricing` the single billing engine:
      the ledger used to RE-price the same usage from a coarse provider table,
      at the full input rate, on token counts that already included cache reads.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Budget

  defp start_budget(opts \\ []) do
    name = :"budget_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Budget, opts, name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  # Rewind the reset deadlines so the NEXT lazy reset is due, exactly as it
  # would be one tick after midnight.
  defp expire_day(name) do
    :sys.replace_state(name, fn state ->
      %{state | daily_reset_at: DateTime.add(DateTime.utc_now(), -60, :second)}
    end)
  end

  describe "record_cost/5 runs the lazy reset before accumulating" do
    test "post-midnight spend survives the next read" do
      name = start_budget()

      # Yesterday's spend.
      GenServer.cast(name, {:record_cost, :anthropic, "claude-sonnet-4", 1_000_000, 0, "s1"})
      _ = GenServer.call(name, :get_status)

      # Midnight passes.
      expire_day(name)

      # Today's first spend, recorded BEFORE anything reads the ledger.
      GenServer.cast(name, {:record_cost, :anthropic, "claude-sonnet-4", 2_000_000, 0, "s2"})

      {:ok, status} = GenServer.call(name, :get_status)

      assert_in_delta status.daily_spent, 6.0, 0.0001

      refute status.daily_spent == 0.0,
             "spend recorded after midnight was accumulated into yesterday's bucket and then erased"
    end
  end

  describe "call counting" do
    test "daily/monthly call counters are their own, not length(entries)" do
      name = start_budget()

      for _ <- 1..5 do
        GenServer.cast(name, {:record_cost, :openai, "gpt-4o", 100, 100, "s"})
      end

      {:ok, status} = GenServer.call(name, :get_status)
      assert status.daily_calls == 5
      assert status.monthly_calls == 5
    end

    test "the call counter keeps counting past the 10 000 entry cap" do
      name = start_budget()

      # Pre-load the ring to its cap, then record one more call.
      :sys.replace_state(name, fn state ->
        %{state | entries: List.duplicate(%{cost: 0.0}, 10_000)}
      end)

      GenServer.cast(name, {:record_cost, :openai, "gpt-4o", 100, 100, "s"})
      {:ok, status} = GenServer.call(name, :get_status)

      assert status.ledger_entries == 10_000
      assert status.daily_calls == 1, "the call count was still derived from the capped list"
    end

    test "a daily reset clears the daily call counter but not the monthly one" do
      name = start_budget()

      GenServer.cast(name, {:record_cost, :openai, "gpt-4o", 100, 100, "s"})
      _ = GenServer.call(name, :get_status)

      expire_day(name)
      {:ok, status} = GenServer.call(name, :get_status)

      assert status.daily_calls == 0
      assert status.monthly_calls == 1
    end
  end

  describe "get_status/0 honesty fields" do
    test "reports that the ledger is not persisted, and since when it has been counting" do
      name = start_budget()
      {:ok, status} = GenServer.call(name, :get_status)

      assert status.persisted == false,
             "the ledger claims to be persisted, but init/1 starts at zero and nothing is saved"

      assert %DateTime{} = status.counting_since
    end
  end

  describe "record_priced_cost/5 — one usage, one price, one engine" do
    test "stores the price it was given rather than re-pricing the tokens" do
      name = start_budget()

      # `Pricing.cost/2`'s answer for a cache-heavy turn. The coarse provider
      # table would bill the same tokens at the full anthropic input rate.
      GenServer.cast(
        name,
        {:record_priced_cost, :anthropic, "claude-sonnet-4", 0.31, 1_000_000, "s1"}
      )

      {:ok, status} = GenServer.call(name, :get_status)

      assert_in_delta status.daily_spent, 0.31, 0.0001
      assert status.daily_tokens == 1_000_000

      # What the old bridge would have charged for the same usage.
      assert Budget.calculate_cost(:anthropic, 1_000_000, 0) == 3.0
    end

    test "a nil/negative price records as zero rather than crashing" do
      name = start_budget()

      GenServer.cast(name, {:record_priced_cost, :anthropic, "m", nil, 10, "s"})
      GenServer.cast(name, {:record_priced_cost, :anthropic, "m", -1.0, 10, "s"})

      {:ok, status} = GenServer.call(name, :get_status)
      assert status.daily_spent == 0.0
      assert status.daily_calls == 2
    end
  end
end
