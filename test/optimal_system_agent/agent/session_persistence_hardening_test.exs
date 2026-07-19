defmodule OptimalSystemAgent.Agent.SessionPersistenceHardeningTest do
  @moduledoc """
  Regression tests for defensive hardening of SessionPersistence:

    * save/3 writes atomically (temp + rename) so a crash cannot truncate the
      session JSON and no .tmp is left behind. (finding 18)
    * load/1 must skip a single malformed (non-map) turn instead of failing the
      whole resume, and tolerate a missing/non-list messages key. (findings 19, 20)
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence

  @dir Path.expand("~/.osa/sessions")

  defp session_file(id) do
    safe = Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
    Path.join(@dir, "#{safe}.json")
  end

  defp updates_file(id) do
    safe = Regex.replace(~r/[^a-zA-Z0-9_\-]/, id, "_")
    Path.join(@dir, "#{safe}.updates.jsonl")
  end

  setup do
    id = "osa_persist_hard_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # save/3 now also maintains the immutable event log; clean its sidecars too.
      Enum.each(
        [session_file(id), updates_file(id), updates_file(id) <> ".lock", updates_file(id) <> ".corrupt"],
        &File.rm/1
      )
    end)

    {:ok, id: id}
  end

  describe "save/3 atomic write (finding 18)" do
    test "produces a valid file and leaves no .tmp behind", %{id: id} do
      assert :ok = SessionPersistence.save(id, [%{role: "user", content: "hi"}])

      path = session_file(id)
      assert File.exists?(path)
      refute File.exists?(path <> ".tmp")

      assert {:ok, %{"messages" => [_ | _]}} = Jason.decode(File.read!(path))
    end
  end

  describe "load/1 tolerance (findings 19, 20)" do
    test "skips a non-map turn instead of failing the whole session", %{id: id} do
      :ok = SessionPersistence.save(id, [%{role: "user", content: "hi"}])

      # Corrupt: inject a bare-string element alongside a valid map.
      corrupt =
        Jason.encode!(%{
          "session_id" => id,
          "messages" => [%{"role" => "user", "content" => "hi"}, "corrupt"]
        })

      File.write!(session_file(id), corrupt)

      assert {:ok, restored} = SessionPersistence.load(id)
      # Pre-fix: Map.new/2 over a non-2-tuple raised → whole session unusable.
      assert Enum.any?(restored, &(is_map(&1) and &1[:role] == "user"))
      # The bad element is filtered out, not fatal.
      assert Enum.all?(restored, &is_map/1)
    end

    test "a non-list messages value loads as an empty session", %{id: id} do
      File.write!(
        session_file(id),
        Jason.encode!(%{"session_id" => id, "messages" => %{"not" => "list"}})
      )

      assert {:ok, []} = SessionPersistence.load(id)
    end
  end

  describe "resume round-trip (save → resolve → load → replay)" do
    # This is the backbone the TUI /resume + /continue picker and the CLI
    # /resume command both depend on: a saved conversation must be resolvable
    # by working directory and load back with restorable role/content turns so
    # the chat view can replay it.
    test "find_latest_for_dir resolves a saved session and load restores turns",
         %{id: id} do
      dir = Path.expand("~/.osa/sessions")

      convo = [
        %{role: "user", content: "first question"},
        %{role: "assistant", content: "first answer"},
        %{role: "user", content: "second question"}
      ]

      assert :ok = SessionPersistence.save(id, convo, dir)

      # Directory-scoped resolution (the /continue + POST /sessions path).
      assert SessionPersistence.find_latest_for_dir(dir) == id

      # Load restores the turns with keys usable by the replay renderers.
      assert {:ok, restored} = SessionPersistence.load(id)
      assert length(restored) == 3

      [u1 | _] = restored
      assert (u1[:role] || u1["role"]) == "user"
      assert (u1[:content] || u1["content"]) == "first question"

      # Only user/assistant text turns are what the chat view replays.
      replayable =
        Enum.filter(restored, fn m ->
          (m[:role] || m["role"]) in ["user", "assistant"] and
            is_binary(m[:content] || m["content"])
        end)

      assert length(replayable) == 3
    end
  end
end
