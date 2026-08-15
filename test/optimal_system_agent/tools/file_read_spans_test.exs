defmodule OptimalSystemAgent.Tools.FileReadSpansTest do
  @moduledoc """
  The interval arithmetic under range subtraction, tested apart from the tool.

  These are the properties the tool's correctness rests on: subtraction never
  invents a line, never drops one that was not held, and the union of what is
  delivered with what is omitted is always exactly what was asked for. A bug
  here does not surface as an error — it surfaces as a model reasoning about a
  file it was never sent.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Spans
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Subtraction

  describe "normalize/1" do
    test "sorts, merges overlaps, and merges adjacent runs" do
      assert Spans.normalize([{10, 20}, {1, 5}, {6, 9}]) == [{1, 20}]
      assert Spans.normalize([{1, 10}, {5, 15}]) == [{1, 15}]
      assert Spans.normalize([{1, 5}, {20, 25}]) == [{1, 5}, {20, 25}]
    end

    test "drops malformed spans instead of raising" do
      assert Spans.normalize([{5, 1}, {0, 3}, {:a, 2}, {1, 2}]) == [{1, 2}]
      assert Spans.normalize(:not_a_list) == []
    end
  end

  describe "subtract/2" do
    test "the whole window when nothing is held" do
      assert Spans.subtract({1, 100}, []) == [{1, 100}]
      assert Spans.subtract({1, 100}, [{200, 300}]) == [{1, 100}]
    end

    test "nothing when the window is covered" do
      assert Spans.subtract({10, 20}, [{1, 100}]) == []
      assert Spans.subtract({10, 20}, [{10, 20}]) == []
      assert Spans.subtract({10, 20}, [{1, 15}, {16, 40}]) == []
    end

    test "the complement, in file order, for a mid-window holding" do
      assert Spans.subtract({1, 100}, [{40, 60}]) == [{1, 39}, {61, 100}]
      assert Spans.subtract({1, 100}, [{1, 20}]) == [{21, 100}]
      assert Spans.subtract({1, 100}, [{80, 200}]) == [{1, 79}]
    end

    test "several holdings produce several spans" do
      assert Spans.subtract({1, 100}, [{20, 30}, {60, 70}]) == [{1, 19}, {31, 59}, {71, 100}]
    end
  end

  describe "subtract and intersect are complements" do
    test "their union is always the original window" do
      window = {1, 200}

      helds = [
        [],
        [{1, 200}],
        [{50, 60}],
        [{1, 10}, {190, 200}],
        [{20, 30}, {31, 40}, {100, 150}],
        [{300, 400}]
      ]

      for held <- helds do
        deliver = Spans.subtract(window, held)
        omitted = Spans.intersect(window, held)

        assert Spans.union(deliver, omitted) == [window] or
                 (omitted == [] and deliver == [window]),
               "deliver=#{inspect(deliver)} omitted=#{inspect(omitted)} for #{inspect(held)}"

        assert Spans.line_count(deliver) + Spans.line_count(omitted) == 200
      end
    end

    test "no line is in both halves" do
      deliver = Spans.subtract({1, 100}, [{30, 50}])
      omitted = Spans.intersect({1, 100}, [{30, 50}])

      for n <- 1..100 do
        assert Spans.member?(deliver, n) != Spans.member?(omitted, n)
      end
    end
  end

  describe "Subtraction.plan/4 — the guards, not the arithmetic" do
    test "does nothing when nothing is held" do
      assert Subtraction.plan({1, 100}, [], 10_000) == :full
    end

    test "does nothing when the window is disjoint from every holding" do
      assert Subtraction.plan({1, 100}, [{500, 600}], 10_000) == :full
    end

    test "reports all-held only when the notice is cheaper than the bytes" do
      assert {:all_held, [{1, 100}]} = Subtraction.plan({1, 100}, [{1, 100}], 10_000)

      # A window smaller than the notice that would replace it: substituting
      # would GROW the transcript, which is not a saving.
      assert Subtraction.plan({1, 3}, [{1, 3}], 40) == :full
    end

    test "declines a subtraction that cannot pay for its own explanation" do
      # 4 lines of a 100-line, 10 KB window: ~400 bytes omitted against ~420
      # bytes of header and marker.
      assert Subtraction.plan({1, 100}, [{50, 53}], 10_000) == :full
    end

    test "takes a subtraction that clears the overhead" do
      assert {:partial, [{1, 39}, {61, 100}], [{40, 60}]} =
               Subtraction.plan({1, 100}, [{40, 60}], 10_000)
    end

    test "declines a result that would be cut into too many pieces" do
      # Technically complete, practically unreadable — and the measured response
      # to an illegible result is another read.
      assert Subtraction.plan({1, 400}, [{50, 90}, {150, 190}, {250, 290}], 40_000) == :full
    end

    test "charges the line-numbering a whole-file read would newly pay" do
      # Identical inputs; the only difference is that a whole-file read has to
      # start numbering its lines the moment any of them are withheld.
      assert {:partial, _, _} = Subtraction.plan({1, 200}, [{40, 159}], 1_600)
      assert Subtraction.plan({1, 200}, [{40, 159}], 1_600, per_delivered_line: 7) == :full
    end

    test "malformed input is always :full — never a withheld read" do
      assert Subtraction.plan({100, 1}, [{1, 50}], 10_000) == :full
      assert Subtraction.plan(:nonsense, [{1, 50}], 10_000) == :full
      assert Subtraction.plan({1, 100}, [{1, 50}], 0) == :full
    end
  end
end
