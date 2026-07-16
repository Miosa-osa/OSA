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

  setup do
    id = "osa_persist_hard_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm(session_file(id)) end)
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
end
