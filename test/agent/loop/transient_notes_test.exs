defmodule OptimalSystemAgent.Agent.Loop.TransientNotesTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.TransientNotes

  defp note(kind, body), do: %{role: "system", content: TransientNotes.header(kind) <> body}

  defp no_progress(n),
    do: %{role: "system", content: "[System: #{n} tool calls with no measured progress — x]"}

  defp user(t), do: %{role: "user", content: t}

  describe "kind_of/1" do
    test "recognises each note by the header its writer uses" do
      assert TransientNotes.kind_of(note(:advisor, " — advice")) == :advisor
      assert TransientNotes.kind_of(note(:output_contract, " — inform] x")) == :output_contract
      assert TransientNotes.kind_of(note(:ledger_recap, "\nrecap")) == :ledger_recap
      assert TransientNotes.kind_of(no_progress(6)) == :no_progress
    end

    test "leaves every other message alone" do
      assert TransientNotes.kind_of(user("[ADVISOR RECOMMENDATION from the user")) == nil
      assert TransientNotes.kind_of(%{role: "system", content: "You are OSA."}) == nil
      assert TransientNotes.kind_of(%{role: "system", content: "[System: something else]"}) == nil
      assert TransientNotes.kind_of(%{role: "system", content: [%{"type" => "text"}]}) == nil
    end

    test "reads string-keyed messages, as restored from disk" do
      assert TransientNotes.kind_of(%{"role" => "system", "content" => "[Output contract — x]"}) ==
               :output_contract
    end
  end

  describe "append/2" do
    test "a new note replaces the earlier note of its kind and keeps the rest in order" do
      history = [
        user("a"),
        note(:advisor, " one"),
        user("b"),
        note(:output_contract, " — direct]"),
        user("c")
      ]

      result = TransientNotes.append(history, [note(:advisor, " two")])

      assert result == [
               user("a"),
               user("b"),
               note(:output_contract, " — direct]"),
               user("c"),
               note(:advisor, " two")
             ]
    end

    test "appending ordinary messages never removes anything" do
      history = [note(:advisor, " one"), user("a")]
      assert TransientNotes.append(history, [user("b")]) == history ++ [user("b")]
    end

    test "a turn of notes stays bounded however many turns run" do
      result =
        Enum.reduce(1..50, [], fn n, acc ->
          TransientNotes.append(acc, [
            note(:output_contract, " — inform] #{n}"),
            note(:ledger_recap, "\n#{n}"),
            user("turn #{n}")
          ])
        end)

      assert length(result) == 52
      assert Enum.count(result, &(TransientNotes.kind_of(&1) != nil)) == 2
    end
  end

  describe "prune/1" do
    test "keeps the last note of each kind and every other message" do
      history =
        [%{role: "system", content: "You are OSA."}] ++
          Enum.flat_map(1..20, fn n ->
            [note(:advisor, " #{n}"), no_progress(n), user("q#{n}")]
          end)

      pruned = TransientNotes.prune(history)

      assert Enum.count(pruned, &(TransientNotes.kind_of(&1) == :advisor)) == 1
      assert Enum.count(pruned, &(TransientNotes.kind_of(&1) == :no_progress)) == 1
      assert note(:advisor, " 20") in pruned
      assert Enum.count(pruned, &(&1.role == "user")) == 20
      assert hd(pruned).content == "You are OSA."
    end
  end
end
