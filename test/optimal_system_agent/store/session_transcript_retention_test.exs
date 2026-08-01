defmodule OptimalSystemAgent.Store.SessionTranscriptRetentionTest do
  @moduledoc """
  Bounds tests for the `session_transcripts` retention policy.

  `session_transcripts` is an archive, not the model's context: compacting a
  session shrinks what is resent to the model and leaves every stored row in
  place. Nothing bounded this table before, so a long-lived install grew it one
  row per turn forever.

  These tests drive rows in and assert the table actually stops growing, plus
  that the FTS5 index stays in sync through the deletes (the `_ad` trigger).

  `async: false` and deliberately destructive: the row-cap half of the policy is
  global by construction, so exercising it removes other suites' leftover rows
  from the throwaway tmp SQLite database (`config/test.exs` gives every run a
  fresh one). No test asserts on another test's rows, so that is safe.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias OptimalSystemAgent.Store.Repo
  alias OptimalSystemAgent.Store.SessionTranscript

  defp sid, do: "osa_retention_#{System.unique_integer([:positive])}"

  defp count_for(session_id) do
    Repo.aggregate(from(t in SessionTranscript, where: t.session_id == ^session_id), :count, :id)
  end

  # Backdate rows so the age half of the policy can see them.
  defp backdate(session_id, days) do
    stamp =
      DateTime.utc_now()
      |> DateTime.add(-days * 86_400, :second)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)

    from(t in SessionTranscript, where: t.session_id == ^session_id)
    |> Repo.update_all(set: [inserted_at: stamp])
  end

  describe "age half of the policy" do
    test "drops rows past the window and keeps rows inside it" do
      old = sid()
      new = sid()

      Enum.each(1..20, fn i -> SessionTranscript.save_turn(old, "user", "old #{i}") end)
      backdate(old, 90)
      Enum.each(1..5, fn i -> SessionTranscript.save_turn(new, "user", "new #{i}") end)

      assert {:ok, %{by_age: by_age}} = SessionTranscript.purge_expired(days: 30, max_rows: 0)

      assert by_age >= 20
      assert count_for(old) == 0
      assert count_for(new) == 5
    end

    test "days: 0 disables the age half" do
      s = sid()
      Enum.each(1..5, fn i -> SessionTranscript.save_turn(s, "user", "m#{i}") end)
      backdate(s, 9999)

      assert {:ok, %{by_age: 0}} = SessionTranscript.purge_expired(days: 0, max_rows: 0)
      assert count_for(s) == 5
    end

    test "the FTS index is kept in sync through an age purge" do
      s = sid()
      token = "zzqretention#{System.unique_integer([:positive])}"
      SessionTranscript.save_turn(s, "user", "please remember #{token}")

      assert Enum.any?(SessionTranscript.search(token), &(&1.session_id == s))

      backdate(s, 9999)
      SessionTranscript.purge_expired(days: 1, max_rows: 0)

      assert count_for(s) == 0

      refute Enum.any?(SessionTranscript.search(token), &(&1.session_id == s)),
             "the session_transcripts_ad trigger must evict the FTS row too"
    end
  end

  describe "row-cap half of the policy — the actual bound" do
    test "300 inserts against a cap of 50 leave exactly 50 rows" do
      s = sid()
      Enum.each(1..300, fn i -> SessionTranscript.save_turn(s, "user", "m#{i}") end)

      assert SessionTranscript.count() >= 300

      assert {:ok, %{by_cap: by_cap}} = SessionTranscript.purge_expired(days: 0, max_rows: 50)
      assert by_cap > 0

      assert SessionTranscript.count() == 50,
             "the row cap must hold exactly, whatever was inserted"
    end

    test "eviction is oldest-first, so the newest turns survive" do
      s = sid()
      Enum.each(1..40, fn i -> SessionTranscript.save_turn(s, "user", "m#{i}") end)

      SessionTranscript.purge_expired(days: 0, max_rows: 10)

      contents =
        from(t in SessionTranscript, where: t.session_id == ^s, order_by: [asc: t.id])
        |> Repo.all()
        |> Enum.map(& &1.content)

      assert contents == Enum.map(31..40, &"m#{&1}")
    end

    test "max_rows: 0 disables the cap half" do
      s = sid()
      Enum.each(1..10, fn i -> SessionTranscript.save_turn(s, "user", "m#{i}") end)
      before = SessionTranscript.count()

      assert {:ok, %{by_cap: 0}} = SessionTranscript.purge_expired(days: 0, max_rows: 0)
      assert SessionTranscript.count() == before
    end

    test "under the cap nothing is removed" do
      before = SessionTranscript.count()
      assert {:ok, %{by_age: 0, by_cap: 0}} =
               SessionTranscript.purge_expired(days: 0, max_rows: before + 1000)

      assert SessionTranscript.count() == before
    end
  end

  test "purge_expired never raises on bad settings" do
    assert {:ok, %{}} = SessionTranscript.purge_expired(days: :nonsense, max_rows: :nonsense)
  end
end
