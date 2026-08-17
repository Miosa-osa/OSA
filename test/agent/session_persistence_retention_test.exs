defmodule OptimalSystemAgent.Agent.SessionPersistenceRetentionTest do
  @moduledoc """
  `cleanupPeriodDays: 0` used to mean "delete EVERY saved session".

  Two independent problems with that:

    * A retention knob whose zero value destroys all history is a footgun. `0`
      reads as "no retention window", and the obvious way to disable a cleanup
      is to zero its period.
    * `Store.SessionTranscript` reads the SAME config value and has always
      treated `days: 0` as "skip the age purge" (asserted in
      `session_transcript_retention_test.exs`). One config key drove two
      subsystems to opposite conclusions.

  Plus a pin escape hatch, so a session worth keeping survives regardless of
  age.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Agent.ActiveSkills
  alias OptimalSystemAgent.Settings

  @two_years_ago 63_072_000

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_retention_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sessions"))

    prev_dir = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)

    on_exit(fn ->
      case prev_dir do
        nil -> Application.delete_env(:optimal_system_agent, :config_dir)
        v -> Application.put_env(:optimal_system_agent, :config_dir, v)
      end

      Settings.set_session("cleanupPeriodDays", nil)
      Settings.set_session("session_pins", nil)
      File.rm_rf(tmp)
    end)

    {:ok, dir: Path.join(tmp, "sessions")}
  end

  # Writes `<id>.json` with an mtime two years in the past — comfortably
  # outside any sane retention window, so anything that survives survived on
  # purpose rather than on a timing accident.
  defp write_ancient_session(dir, id) do
    path = Path.join(dir, "#{id}.json")
    File.write!(path, Jason.encode!(%{session_id: id, messages: []}))

    old = System.system_time(:second) - @two_years_ago

    old_datetime =
      old
      |> DateTime.from_unix!()
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()

    File.touch!(path, old_datetime)
    path
  end

  describe "cleanupPeriodDays: 0" do
    test "disables retention instead of deleting every saved session", %{dir: dir} do
      a = write_ancient_session(dir, "keep-me-a")
      b = write_ancient_session(dir, "keep-me-b")

      Settings.set_session("cleanupPeriodDays", 0)

      assert {:ok, 0} = SessionPersistence.purge_expired(),
             "0 must mean `retention disabled`, not `purge everything`"

      assert File.exists?(a)
      assert File.exists?(b)
    end

    test "agrees with Store.SessionTranscript, which already read 0 as skip-age-purge",
         %{dir: dir} do
      path = write_ancient_session(dir, "cross-subsystem")
      Settings.set_session("cleanupPeriodDays", 0)

      {:ok, removed} = SessionPersistence.purge_expired()

      assert removed == 0
      assert File.exists?(path), "one config key must not drive two subsystems oppositely"
    end
  end

  describe "a positive retention window still purges" do
    test "an ancient session is removed when days > 0", %{dir: dir} do
      path = write_ancient_session(dir, "genuinely-expired")
      Settings.set_session("cleanupPeriodDays", 30)

      assert {:ok, 1} = SessionPersistence.purge_expired()
      refute File.exists?(path)
    end

    test "purging an ancient session removes its selected-skill checkpoint", %{dir: dir} do
      _path = write_ancient_session(dir, "expired-with-skills")
      assert :ok = ActiveSkills.select("expired-with-skills", "diagnosing-bugs")
      assert ActiveSkills.exists?("expired-with-skills")
      Settings.set_session("cleanupPeriodDays", 30)

      assert {:ok, 1} = SessionPersistence.purge_expired()
      refute ActiveSkills.exists?("expired-with-skills")
    end

    test "a fresh session survives a positive window", %{dir: dir} do
      path = Path.join(dir, "fresh.json")
      File.write!(path, Jason.encode!(%{session_id: "fresh", messages: []}))

      Settings.set_session("cleanupPeriodDays", 30)

      assert {:ok, 0} = SessionPersistence.purge_expired()
      assert File.exists?(path)
    end
  end

  describe "pins" do
    test "a session with a .pin sidecar survives an expired window", %{dir: dir} do
      pinned = write_ancient_session(dir, "pinned-one")
      doomed = write_ancient_session(dir, "doomed-one")

      assert :ok = SessionPersistence.pin("pinned-one")
      assert SessionPersistence.pinned?("pinned-one")

      Settings.set_session("cleanupPeriodDays", 30)

      assert {:ok, 1} = SessionPersistence.purge_expired()
      assert File.exists?(pinned), "a pinned session must never be age-purged"
      refute File.exists?(doomed)
    end

    test "the session_pins setting pins without a sidecar", %{dir: dir} do
      pinned = write_ancient_session(dir, "config-pinned")
      doomed = write_ancient_session(dir, "config-doomed")

      Settings.set_session("session_pins", ["config-pinned"])
      Settings.set_session("cleanupPeriodDays", 30)

      assert {:ok, 1} = SessionPersistence.purge_expired()
      assert File.exists?(pinned)
      refute File.exists?(doomed)
    end

    test "unpin returns a session to normal retention", %{dir: dir} do
      path = write_ancient_session(dir, "temporarily-pinned")

      :ok = SessionPersistence.pin("temporarily-pinned")
      assert :ok = SessionPersistence.unpin("temporarily-pinned")
      refute SessionPersistence.pinned?("temporarily-pinned")

      Settings.set_session("cleanupPeriodDays", 30)

      assert {:ok, 1} = SessionPersistence.purge_expired()
      refute File.exists?(path)
    end

    test "unpinning a session that was never pinned is a no-op, not an error" do
      assert :ok = SessionPersistence.unpin("never-pinned")
      refute SessionPersistence.pinned?("never-pinned")
    end
  end

  describe "the .pin sidecar is invisible to session enumeration" do
    test "list/1 does not surface pins as sessions", %{dir: dir} do
      write_ancient_session(dir, "real-session")
      :ok = SessionPersistence.pin("real-session")

      ids = SessionPersistence.list() |> Enum.map(& &1.session_id)

      assert "real-session" in ids
      refute "real-session.pin" in ids
      assert length(ids) == 1, "the .pin sidecar must not read as a second session record"
    end

    test "delete/1 retires the pin sidecar with the session", %{dir: dir} do
      write_ancient_session(dir, "deleted-session")
      :ok = SessionPersistence.pin("deleted-session")

      SessionPersistence.delete("deleted-session")

      refute File.exists?(Path.join(dir, "deleted-session.pin")),
             "a deleted session must not leave a pin behind to shadow a reused id"
    end
  end
end
