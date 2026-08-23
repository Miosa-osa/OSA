defmodule OptimalSystemAgent.Security.NotesStoreTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.NotesStore

  # Each test uses a unique session id so the per-session GenServer
  # doesn't collide. We start the store explicitly and stop it at the end.
  setup do
    session_id = "notes-test-#{System.unique_integer([:positive])}"
    {:ok, _pid} = NotesStore.ensure_started(session_id)
    on_exit(fn -> NotesStore.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  describe "put/3 and get/2" do
    test "creates and retrieves a valid note", %{session_id: sid} do
      {:ok, note} =
        NotesStore.put(sid, "creds_ssh", %{
          category: :credential,
          content: "SSH creds from hydra",
          username: "root",
          password: "toor",
          target: "10.0.0.1",
          protocol: "ssh"
        })

      assert note.key == "creds_ssh"
      assert note.category == :credential
      assert note.username == "root"

      assert {:ok, fetched} = NotesStore.get(sid, "creds_ssh")
      assert fetched.username == "root"
    end

    test "rejects an invalid note", %{session_id: sid} do
      {:error, reason} =
        NotesStore.put(sid, "bad", %{category: :credential, target: "10.0.0.1"})

      assert String.contains?(reason, "username")
    end

    test "get on missing key returns :not_found", %{session_id: sid} do
      assert :not_found = NotesStore.get(sid, "nope")
    end

    test "put replaces an existing note", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "v", %{
          category: :vulnerability,
          target: "10.0.0.1",
          cve: "CVE-2024-1"
        })

      {:ok, _} =
        NotesStore.put(sid, "v", %{
          category: :vulnerability,
          target: "10.0.0.1",
          cve: "CVE-2024-2"
        })

      assert {:ok, note} = NotesStore.get(sid, "v")
      assert note.cve == "CVE-2024-2"
    end
  end

  describe "list/2 and count/2" do
    test "lists all notes", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "c1", %{
          category: :credential,
          username: "a",
          password: "b",
          target: "10.0.0.1"
        })

      {:ok, _} =
        NotesStore.put(sid, "v1", %{
          category: :vulnerability,
          target: "10.0.0.1",
          cve: "CVE-1"
        })

      notes = NotesStore.list(sid)
      assert length(notes) == 2
      assert Enum.sort(Enum.map(notes, & &1.key)) == ["c1", "v1"]
    end

    test "filters by category", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "c1", %{
          category: :credential,
          username: "a",
          password: "b",
          target: "10.0.0.1"
        })

      {:ok, _} =
        NotesStore.put(sid, "v1", %{
          category: :vulnerability,
          target: "10.0.0.1",
          cve: "CVE-1"
        })

      creds = NotesStore.list(sid, :credential)
      assert length(creds) == 1
      assert hd(creds).key == "c1"
    end

    test "count respects category filter", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "c1", %{
          category: :credential,
          username: "a",
          password: "b",
          target: "10.0.0.1"
        })

      {:ok, _} =
        NotesStore.put(sid, "c2", %{
          category: :credential,
          username: "x",
          password: "y",
          target: "10.0.0.2"
        })

      {:ok, _} =
        NotesStore.put(sid, "v1", %{
          category: :vulnerability,
          target: "10.0.0.1",
          cve: "CVE-1"
        })

      assert NotesStore.count(sid) == 3
      assert NotesStore.count(sid, :credential) == 2
      assert NotesStore.count(sid, :vulnerability) == 1
      assert NotesStore.count(sid, :info) == 0
    end
  end

  describe "delete/2 and clear/1" do
    test "deletes a note", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "c1", %{
          category: :credential,
          username: "a",
          password: "b",
          target: "10.0.0.1"
        })

      assert :ok = NotesStore.delete(sid, "c1")
      assert :not_found = NotesStore.get(sid, "c1")
    end

    test "delete on missing key returns :not_found", %{session_id: sid} do
      assert :not_found = NotesStore.delete(sid, "nope")
    end

    test "clear empties the store", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "c1", %{
          category: :credential,
          username: "a",
          password: "b",
          target: "10.0.0.1"
        })

      assert :ok = NotesStore.clear(sid)
      assert NotesStore.list(sid) == []
      assert NotesStore.count(sid) == 0
    end
  end

  describe "graph/1 and build_graph/1" do
    test "graph builds from notes and returns hosts", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "f1", %{
          category: :finding,
          content: "nmap scan",
          target: "10.0.0.1",
          services: [%{port: 22, product: "OpenSSH", version: "8.9", protocol: "tcp"}]
        })

      graph = NotesStore.graph(sid)
      hosts = OptimalSystemAgent.Security.ShadowGraph.hosts(graph)
      assert length(hosts) == 1
      assert String.contains?(hd(hosts).label, "10.0.0.1")
    end

    test "graph is cached and invalidated on put", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "f1", %{
          category: :finding,
          content: "scan",
          target: "10.0.0.1",
          services: [%{port: 22, protocol: "tcp"}]
        })

      g1 = NotesStore.graph(sid)
      assert length(OptimalSystemAgent.Security.ShadowGraph.hosts(g1)) == 1

      # Adding a note invalidates the cache
      {:ok, _} =
        NotesStore.put(sid, "f2", %{
          category: :finding,
          content: "scan2",
          target: "10.0.0.2",
          services: [%{port: 80, protocol: "tcp"}]
        })

      g2 = NotesStore.graph(sid)
      assert length(OptimalSystemAgent.Security.ShadowGraph.hosts(g2)) == 2
    end

    test "build_graph forces a rebuild", %{session_id: sid} do
      {:ok, _} =
        NotesStore.put(sid, "f1", %{
          category: :finding,
          content: "scan",
          target: "10.0.0.1",
          services: [%{port: 22, protocol: "tcp"}]
        })

      g = NotesStore.build_graph(sid)
      assert length(OptimalSystemAgent.Security.ShadowGraph.hosts(g)) == 1
    end

    test "empty store produces an empty graph", %{session_id: sid} do
      g = NotesStore.graph(sid)
      assert OptimalSystemAgent.Security.ShadowGraph.hosts(g) == []
    end
  end

  describe "ensure_started/1" do
    test "is idempotent for the same session" do
      sid = "idempotent-#{System.unique_integer([:positive])}"
      {:ok, pid1} = NotesStore.ensure_started(sid)
      {:ok, pid2} = NotesStore.ensure_started(sid)
      assert pid1 == pid2
      NotesStore.stop(sid)
    end
  end
end
