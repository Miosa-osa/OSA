defmodule OptimalSystemAgent.OpenComputers.Session.BackoffTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Session.Backoff

  describe "initial/0" do
    test "returns 1000 ms" do
      assert Backoff.initial() == 1_000
    end
  end

  describe "max/0" do
    test "returns 60_000 ms" do
      assert Backoff.max() == 60_000
    end
  end

  describe "next/1" do
    test "doubles the current delay" do
      assert Backoff.next(1_000) == 2_000
    end

    test "doubles from 2000 to 4000" do
      assert Backoff.next(2_000) == 4_000
    end

    test "doubles from 500 to 1000" do
      assert Backoff.next(500) == 1_000
    end

    test "caps at 60_000 when doubling would exceed max" do
      assert Backoff.next(60_000) == 60_000
    end

    test "caps exactly when next would be 2x max" do
      assert Backoff.next(40_000) == 60_000
    end

    test "caps when current is already above half of max" do
      assert Backoff.next(31_000) == 60_000
    end

    test "does not cap when doubling stays under max" do
      assert Backoff.next(29_000) == 58_000
    end

    test "works from initial value" do
      assert Backoff.next(Backoff.initial()) == 2_000
    end
  end

  describe "with_jitter/1" do
    test "returns a value >= base" do
      base = 5_000
      result = Backoff.with_jitter(base)
      assert result >= base
    end

    test "returns a value at most base + 200" do
      base = 5_000
      result = Backoff.with_jitter(base)
      assert result <= base + 200
    end

    test "returns an integer" do
      assert is_integer(Backoff.with_jitter(1_000))
    end

    test "jitter range is within 1..200" do
      base = 1_000
      # Run many times to ensure jitter stays bounded
      results = for _ <- 1..100, do: Backoff.with_jitter(base)
      assert Enum.all?(results, fn r -> r >= base and r <= base + 200 end)
    end
  end
end
