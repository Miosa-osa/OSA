defmodule OptimalSystemAgent.Integration.MemoryTest do
  # Memory tests share the GenServer process — no async
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Memory

  # ---------------------------------------------------------------------------
  # Session management
  # ---------------------------------------------------------------------------

  describe "session management" do
    test "append and load_session roundtrips correctly" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      Memory.append(session_id, %{role: "user", content: "Hello agent"})
      Memory.append(session_id, %{role: "assistant", content: "Hi! How can I help?"})

      # GenServer.cast is async — wait for filesystem write
      Process.sleep(150)

      messages = Memory.load_session(session_id)
      assert length(messages) == 2
      assert Enum.at(messages, 0)["content"] == "Hello agent"
      assert Enum.at(messages, 1)["content"] == "Hi! How can I help?"
    after
      cleanup_session("test-session-#{System.unique_integer([:positive])}")
    end

    test "load_session returns empty list for non-existent session" do
      session_id = "nonexistent-session-#{System.unique_integer([:positive])}"
      messages = Memory.load_session(session_id)
      assert messages == []
    end

    test "multiple messages preserve insertion order" do
      session_id = "test-order-#{System.unique_integer([:positive])}"

      for i <- 1..5 do
        Memory.append(session_id, %{role: "user", content: "Message #{i}"})
      end

      Process.sleep(150)

      messages = Memory.load_session(session_id)
      assert length(messages) == 5

      contents = Enum.map(messages, & &1["content"])
      assert contents == ["Message 1", "Message 2", "Message 3", "Message 4", "Message 5"]
    after
      cleanup_sessions_with_prefix("test-order-")
    end

    test "appended messages include a timestamp field" do
      session_id = "test-timestamp-#{System.unique_integer([:positive])}"
      Memory.append(session_id, %{role: "user", content: "Check my timestamp"})

      Process.sleep(150)

      messages = Memory.load_session(session_id)
      assert length(messages) == 1
      assert Map.has_key?(List.first(messages), "timestamp")
    after
      cleanup_sessions_with_prefix("test-timestamp-")
    end

    test "list_sessions returns a list" do
      sessions = Memory.list_sessions()
      assert is_list(sessions)
    end

    test "list_sessions entries have expected shape when sessions exist" do
      session_id = "test-list-#{System.unique_integer([:positive])}"
      Memory.append(session_id, %{role: "user", content: "Test for list"})
      Process.sleep(150)

      sessions = Memory.list_sessions()
      assert is_list(sessions)

      # Each entry should be a map with session_id
      Enum.each(sessions, fn session ->
        assert is_map(session)
        assert Map.has_key?(session, :session_id)
        assert Map.has_key?(session, :message_count)
      end)
    after
      cleanup_sessions_with_prefix("test-list-")
    end

    test "memory_stats returns a map" do
      stats = Memory.memory_stats()
      assert is_map(stats)
    end

    test "memory_stats includes expected keys" do
      stats = Memory.memory_stats()

      assert Map.has_key?(stats, :entry_count)
      assert Map.has_key?(stats, :session_count)
      assert Map.has_key?(stats, :memory_file_bytes)
    end

    test "memory_stats session_count is a non-negative integer" do
      stats = Memory.memory_stats()
      assert is_integer(stats.session_count)
      assert stats.session_count >= 0
    end

    test "memory_stats entry_count is a non-negative integer" do
      stats = Memory.memory_stats()
      assert is_integer(stats.entry_count)
      assert stats.entry_count >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # Resume session
  # ---------------------------------------------------------------------------

  describe "resume_session" do
    test "returns {:ok, messages} for a session that exists" do
      session_id = "test-resume-#{System.unique_integer([:positive])}"
      Memory.append(session_id, %{role: "user", content: "Resume me"})
      Process.sleep(150)

      result = Memory.resume_session(session_id)
      assert {:ok, messages} = result
      assert is_list(messages)
      assert length(messages) == 1
    after
      cleanup_sessions_with_prefix("test-resume-")
    end

    test "returns {:error, :not_found} for a session that does not exist" do
      result =
        Memory.resume_session("totally-nonexistent-session-#{System.unique_integer([:positive])}")

      assert {:error, :not_found} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Long-term memory (recall)
  # ---------------------------------------------------------------------------

  describe "recall" do
    test "recall returns a string" do
      result = Memory.recall()
      assert is_binary(result)
    end

    test "recall_relevant returns a string" do
      result = Memory.recall_relevant("database connection pool configuration", 500)
      assert is_binary(result)
    end

    test "recall_relevant with empty query returns a string" do
      result = Memory.recall_relevant("", 500)
      assert is_binary(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Keyword extraction (public @doc false helper)
  # ---------------------------------------------------------------------------

  describe "parse_memory_entries" do
    test "parses a well-formed MEMORY.md entry" do
      content = """
      ## [decision] 2026-02-27T10:00:00Z
      Use PostgreSQL for production — SQLite is only for development.

      ## [preference] 2026-02-27T11:00:00Z
      User prefers concise answers without preamble.
      """

      entries = Memory.parse_memory_entries(content)
      assert length(entries) == 2

      {_id1, entry1} = List.first(entries)
      assert entry1[:category] == "decision"
      assert String.contains?(entry1[:content], "PostgreSQL")

      {_id2, entry2} = List.last(entries)
      assert entry2[:category] == "preference"
    end

    test "returns empty list for empty content" do
      assert Memory.parse_memory_entries("") == []
    end

    test "returns empty list for content with no valid headers" do
      assert Memory.parse_memory_entries("just some random text without headers") == []
    end

    test "each parsed entry has required fields" do
      content = "## [bug] 2026-02-27T09:00:00Z\nFound memory leak in the worker process.\n"
      entries = Memory.parse_memory_entries(content)

      assert length(entries) == 1
      {_id, entry} = List.first(entries)

      assert Map.has_key?(entry, :id)
      assert Map.has_key?(entry, :category)
      assert Map.has_key?(entry, :timestamp)
      assert Map.has_key?(entry, :content)
      assert Map.has_key?(entry, :importance)
    end
  end

  # ---------------------------------------------------------------------------
  # Keyword extraction
  # ---------------------------------------------------------------------------

  describe "extract_keywords" do
    test "extracts meaningful words from a message" do
      keywords = Memory.extract_keywords("Build a REST API for user authentication")
      assert is_list(keywords)
      assert length(keywords) > 0
    end

    test "filters out common stop words" do
      keywords = Memory.extract_keywords("the quick brown fox and the lazy dog")
      # Stop words like "the", "and" should be removed
      refute "the" in keywords
      refute "and" in keywords
    end

    test "filters out words shorter than 3 characters" do
      keywords = Memory.extract_keywords("do it now")
      refute "do" in keywords
      refute "it" in keywords
    end

    test "returns empty list for empty string" do
      assert Memory.extract_keywords("") == []
    end

    test "returns deduplicated keywords" do
      keywords = Memory.extract_keywords("database database database connection")
      assert Enum.uniq(keywords) == keywords
    end

    test "lowercases all keywords" do
      keywords = Memory.extract_keywords("PostgreSQL Database Connection")
      assert Enum.all?(keywords, fn kw -> kw == String.downcase(kw) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Search
  # ---------------------------------------------------------------------------

  describe "search" do
    test "search returns a list" do
      results = Memory.search("database")
      assert is_list(results)
    end

    test "search with category filter returns a list" do
      results = Memory.search("anything", category: "decision")
      assert is_list(results)
    end

    test "search respects limit option" do
      results = Memory.search("the", limit: 3)
      assert length(results) <= 3
    end

    test "search results are maps when non-empty" do
      # Seed some memory content first
      Memory.remember("Test architecture decision: use GenServer for state", "architecture")
      Process.sleep(100)

      results = Memory.search("architecture")

      Enum.each(results, fn result ->
        assert is_map(result)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp cleanup_session(session_id) do
    path = Path.expand("~/.osa/sessions/#{session_id}.jsonl")
    File.rm(path)
  end

  defp cleanup_sessions_with_prefix(prefix) do
    sessions_dir = Path.expand("~/.osa/sessions")

    if File.exists?(sessions_dir) do
      case File.ls(sessions_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.each(fn file ->
            File.rm(Path.join(sessions_dir, file))
          end)

        _ ->
          :ok
      end
    end
  end
end
