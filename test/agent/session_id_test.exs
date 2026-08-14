defmodule OptimalSystemAgent.Agent.SessionIdTest do
  @moduledoc """
  A session id is a persistence key. `~/.osa/sessions/<id>.json` is the
  transcript `Loop.init/1` replays when there is no checkpoint, and
  `<id>.spend.json` is the durable bill. So an id handed to a FRESH session that
  another session already used does not merely clash — the new run inherits the
  old run's conversation and its cost.

  That happened. Two of six measured benchmark runs published a spend record
  contaminated by an earlier session, caught only because the input-token total
  was cross-checked against the sum of the run's own per-turn logs.

  The cause: `mix osa.run` (and the SDK, the HTTP tool routes, the MCP server
  dispatcher) built ids out of `System.unique_integer([:positive])`, which is
  unique *within one BEAM instance*. Every `osa` invocation is its own BEAM, so
  the counter restarts near zero on every run — measured across five fresh boots
  on the dev machine: `2564, 2567, 2566, 390, 10`.

  These tests pin the two properties that fix it, and — just as important — the
  one that must NOT change: an explicitly requested id is still returned
  verbatim, because `--resume` reusing a session's artifacts is the entire point
  of resuming. A "fix" that made resume mint a new id would be worse than the bug.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionId
  alias OptimalSystemAgent.Agent.SessionPersistence

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_sid_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sessions"))

    prev = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:optimal_system_agent, :config_dir)
        v -> Application.put_env(:optimal_system_agent, :config_dir, v)
      end

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "generate/1" do
    test "two sessions started in the same millisecond do not collide" do
      # Tighter than the requirement (same *second*): 500 ids drawn in a burst,
      # which on this machine spans single-digit milliseconds, so the timestamp
      # component is doing almost no work and the random tail carries the
      # uniqueness. Under the old `System.unique_integer/1` scheme this test
      # would still pass IN-process — the counter is unique within a BEAM — which
      # is exactly why the next test exists.
      ids = for _ <- 1..500, do: SessionId.generate("headless")

      assert length(Enum.uniq(ids)) == 500
    end

    test "ids do not repeat across simulated BEAM restarts" do
      # The failure the in-process test cannot see. `System.unique_integer/1`
      # restarts from a small integer on every boot, so a fresh process re-walks
      # the same id space; a *time + entropy* id cannot. Simulated by drawing in
      # separate processes with no shared counter state, then asserting no id is
      # small/enumerable enough to be re-drawn.
      ids =
        1..50
        |> Task.async_stream(fn _ -> SessionId.generate("headless") end, max_concurrency: 8)
        |> Enum.map(fn {:ok, id} -> id end)

      assert length(Enum.uniq(ids)) == 50

      for id <- ids do
        assert [_prefix, ms, rand] = String.split(id, "-")
        assert String.to_integer(ms) > 1_700_000_000_000
        assert String.length(rand) == 12
      end
    end

    test "refuses an id whose spend record already exists" do
      # Uniqueness by entropy makes an overwrite improbable. This makes it
      # impossible: the generator asks the persistence layer whether anything is
      # already filed under the name before handing it out.
      taken = SessionId.generate("headless")
      :ok = SessionPersistence.save_spend(taken, %{cost_usd: 4.20, input_tokens: 999})

      refute SessionId.generate("headless") == taken

      # And the record that was there is still there, unclobbered.
      assert %{cost_usd: 4.20, input_tokens: 999, complete: true} =
               SessionPersistence.load_spend(taken)
    end

    test "survives the filename escaping SessionPersistence applies" do
      # `spend_path/1` rewrites anything outside [a-zA-Z0-9_-] to "_", so two
      # distinct ids could map to ONE file. A generated id must round-trip
      # unchanged or the disk check it just passed would be checking a different
      # name than the one that gets written.
      id = SessionId.generate("head less/../..")
      assert id == Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
    end
  end

  describe "resolve/2" do
    test "an explicitly requested id is returned verbatim — resume must keep working" do
      assert SessionId.resolve("my-existing-session", "headless") == "my-existing-session"
    end

    test "an explicit id is returned even when its artifacts exist — that IS resume" do
      :ok = SessionPersistence.save_spend("resumed-run", %{cost_usd: 1.5})

      assert SessionId.resolve("resumed-run", "headless") == "resumed-run"
      assert SessionPersistence.load_spend("resumed-run").cost_usd == 1.5
    end

    test "an absent or blank id mints a fresh one" do
      assert String.starts_with?(SessionId.resolve(nil, "headless"), "headless-")
      assert String.starts_with?(SessionId.resolve("", "headless"), "headless-")
    end
  end

  describe "SessionPersistence.exists?/1" do
    test "sees the spend sidecar, not just the transcript" do
      # The measured symptom was a contaminated `<id>.spend.json` on a run whose
      # transcript had already been purged. A transcript-only existence check
      # would have walked straight past it.
      refute SessionPersistence.exists?("ghost")
      :ok = SessionPersistence.save_spend("ghost", %{cost_usd: 0.01})
      assert SessionPersistence.exists?("ghost")
    end
  end
end
