defmodule OptimalSystemAgent.Channels.HTTP.API.CommandPaletteTest do
  @moduledoc """
  Tests for the fuzzy command palette: GET /commands?q=term

  When a `q` query param is present the commands endpoint returns a merged,
  ranked list of matching commands and skills. Without `q` it returns the
  full unfiltered command list (existing behaviour, regression tests included).
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes
  alias OptimalSystemAgent.Tools.Registry

  @opts ToolRoutes.init([])
  @suffix System.unique_integer([:positive]) |> Integer.to_string()

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp get_commands(query_string \\ "") do
    path = if query_string == "", do: "/", else: "/?#{query_string}"

    conn(:get, path)
    |> put_script_name(["commands"])
    |> ToolRoutes.call(@opts)
  end

  defp execute_command(params) do
    conn(:post, "/execute", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(
      Plug.Parsers.init(parsers: [:json], pass: ["application/json"], json_decoder: Jason)
    )
    |> put_script_name(["commands"])
    |> ToolRoutes.call(@opts)
  end

  defp put_script_name(conn, names) do
    %{conn | script_name: names}
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp seed_skill(name, description, triggers) do
    current = :persistent_term.get({Registry, :skills}, %{})

    skill = %{
      name: name,
      description: description,
      triggers: triggers,
      instructions: "Instructions for #{name}",
      category: "test",
      priority: 10
    }

    :persistent_term.put({Registry, :skills}, Map.put(current, name, skill))
  end

  defp cleanup_skill(name) do
    current = :persistent_term.get({Registry, :skills}, %{})
    :persistent_term.put({Registry, :skills}, Map.delete(current, name))
  end

  # ── Existing behaviour: GET /commands without q ──────────────────────────────

  describe "GET /commands — no q param (full list)" do
    test "returns 200" do
      conn = get_commands()
      assert conn.status == 200
    end

    test "response has commands and count keys" do
      conn = get_commands()
      body = decode(conn)
      assert Map.has_key?(body, "commands")
      assert Map.has_key?(body, "count")
    end

    test "count equals length of commands list" do
      conn = get_commands()
      body = decode(conn)
      assert body["count"] == length(body["commands"])
    end

    test "each command entry has name, description, category" do
      conn = get_commands()
      body = decode(conn)

      Enum.each(body["commands"], fn cmd ->
        assert Map.has_key?(cmd, "name")
        assert Map.has_key?(cmd, "description")
        assert Map.has_key?(cmd, "category")
      end)
    end

    test "well-known built-in commands are included" do
      conn = get_commands()
      body = decode(conn)
      names = Enum.map(body["commands"], fn c -> c["name"] end)
      assert "help" in names
      assert "status" in names
      assert "agents" in names
    end

    test "does not advertise commands without executable handlers" do
      conn = get_commands()
      body = decode(conn)
      names = Enum.map(body["commands"], fn c -> c["name"] end)

      refute "reload" in names
      refute "debug" in names
      refute "mem-search" in names
      refute "mem-save" in names
      refute "mem-recall" in names
    end
  end

  describe "POST /commands/execute" do
    test "returns the TUI command result contract for executable commands" do
      conn =
        execute_command(%{
          "command" => "agents",
          "arg" => "",
          "session_id" => "command-test"
        })

      assert conn.status == 200
      body = decode(conn)
      assert body["kind"] == "info"
      assert body["command"] == "agents"
      assert is_binary(body["output"])
      assert body["output"] =~ "Agent"
    end

    test "combines the TUI arg field with command before dispatching" do
      missing_session = "missing-session-#{@suffix}"

      conn =
        execute_command(%{
          "command" => "resume",
          "arg" => missing_session,
          "session_id" => "command-test"
        })

      assert conn.status == 200
      body = decode(conn)
      assert body["kind"] == "info"
      assert body["command"] == "resume #{missing_session}"
      assert body["output"] =~ "Session '#{missing_session}' not found"
    end

    test "blocked commands return an error kind instead of executing" do
      conn =
        execute_command(%{
          "command" => "exit",
          "arg" => "",
          "session_id" => "command-test"
        })

      assert conn.status == 200
      body = decode(conn)
      assert body["kind"] == "error"
      assert body["output"] =~ "not available via HTTP"
    end

    test "all advertised commands execute through the TUI HTTP contract" do
      commands =
        get_commands()
        |> decode()
        |> Map.fetch!("commands")
        |> Enum.map(&Map.fetch!(&1, "name"))

      for command <- commands do
        conn =
          execute_command(%{
            "command" => command,
            "arg" => "",
            "session_id" => "command-smoke-#{@suffix}"
          })

        assert conn.status == 200

        body = decode(conn)
        assert body["kind"] in ["info", "error", "prompt", "action"]
        assert is_binary(body["output"])
      end
    end
  end

  # ── Fuzzy palette: GET /commands?q=term — response structure ─────────────────

  describe "GET /commands?q=term — response structure" do
    test "returns 200" do
      conn = get_commands("q=help")
      assert conn.status == 200
    end

    test "response has results, count, and query keys" do
      conn = get_commands("q=help")
      body = decode(conn)
      assert Map.has_key?(body, "results")
      assert Map.has_key?(body, "count")
      assert Map.has_key?(body, "query")
    end

    test "query field echoes the search term" do
      conn = get_commands("q=help")
      body = decode(conn)
      assert body["query"] == "help"
    end

    test "count equals length of results list" do
      conn = get_commands("q=help")
      body = decode(conn)
      assert body["count"] == length(body["results"])
    end

    test "each result has type, name, description, category, score" do
      conn = get_commands("q=status")
      body = decode(conn)

      Enum.each(body["results"], fn item ->
        assert Map.has_key?(item, "type")
        assert Map.has_key?(item, "name")
        assert Map.has_key?(item, "description")
        assert Map.has_key?(item, "category")
        assert Map.has_key?(item, "score")
      end)
    end

    test "score is a number" do
      conn = get_commands("q=status")
      body = decode(conn)

      Enum.each(body["results"], fn item ->
        assert is_number(item["score"])
      end)
    end

    test "type is either 'command' or 'skill'" do
      conn = get_commands("q=status")
      body = decode(conn)

      Enum.each(body["results"], fn item ->
        assert item["type"] in ["command", "skill"]
      end)
    end

    test "results are sorted by score descending" do
      conn = get_commands("q=help")
      body = decode(conn)
      scores = Enum.map(body["results"], fn item -> item["score"] end)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  # ── Fuzzy palette: matching accuracy ─────────────────────────────────────────

  describe "GET /commands?q=term — matching behavior" do
    test "exact name match returns the command" do
      conn = get_commands("q=help")
      body = decode(conn)
      names = Enum.map(body["results"], fn r -> r["name"] end)
      assert "help" in names
    end

    test "prefix match returns commands starting with query" do
      conn = get_commands("q=mem")
      body = decode(conn)
      names = Enum.map(body["results"], fn r -> r["name"] end)
      # mem-search, mem-save, mem-recall, etc. all start with "mem"
      assert Enum.any?(names, fn n -> String.starts_with?(n, "mem") end)
    end

    test "substring match returns commands containing query" do
      conn = get_commands("q=search")
      body = decode(conn)
      names = Enum.map(body["results"], fn r -> r["name"] end)
      assert Enum.any?(names, fn n -> String.contains?(n, "search") end)
    end

    test "query with no matches returns empty results" do
      # A query that will not match any command name or description
      conn = get_commands("q=xyzzy_no_match_ever_#{@suffix}")
      body = decode(conn)
      assert body["count"] == 0
      assert body["results"] == []
    end

    test "exact match scores higher than substring match" do
      conn = get_commands("q=reload")
      body = decode(conn)

      exact = Enum.find(body["results"], fn r -> r["name"] == "reload" end)
      others = Enum.filter(body["results"], fn r -> r["name"] != "reload" end)

      if exact && others != [] do
        max_other_score = Enum.max_by(others, fn r -> r["score"] end).score
        assert exact["score"] >= max_other_score
      end
    end

    test "empty q param falls back to full command list" do
      conn = get_commands("q=")
      body = decode(conn)
      # Empty q treated as absent — returns the full list format
      assert Map.has_key?(body, "commands")
    end
  end

  # ── Fuzzy palette: skills are included ───────────────────────────────────────

  describe "GET /commands?q=term — skills merged into results" do
    setup do
      name = "palette-skill-#{@suffix}"
      seed_skill(name, "Palette test skill for fuzzy search #{@suffix}", ["palette#{@suffix}"])
      on_exit(fn -> cleanup_skill(name) end)
      {:ok, skill_name: name}
    end

    test "skill matching the query appears in results", %{skill_name: name} do
      # Use the skill name as the search term so it matches via description search
      conn = get_commands("q=palette#{@suffix}")
      body = decode(conn)
      names = Enum.map(body["results"], fn r -> r["name"] end)
      assert name in names
    end

    test "matched skill has type 'skill'", %{skill_name: name} do
      conn = get_commands("q=palette#{@suffix}")
      body = decode(conn)
      skill_entry = Enum.find(body["results"], fn r -> r["name"] == name end)
      assert skill_entry != nil
      assert skill_entry["type"] == "skill"
    end

    test "results can contain both commands and skills" do
      # A broad term that matches some commands and potentially skills
      conn = get_commands("q=palette#{@suffix}")
      body = decode(conn)
      types = Enum.map(body["results"], fn r -> r["type"] end) |> Enum.uniq()
      # At minimum we expect "skill" to appear (seeded above)
      assert "skill" in types
    end
  end

  # ── Regression: existing tool/skill list endpoints unaffected ────────────────

  describe "GET /tools — unaffected by palette changes" do
    test "returns tools list" do
      conn =
        conn(:get, "/")
        |> put_script_name(["tools"])
        |> ToolRoutes.call(@opts)

      assert conn.status == 200
      body = decode(conn)
      assert Map.has_key?(body, "tools")
    end
  end

  describe "GET /skills — unaffected by palette changes" do
    test "returns skills list" do
      conn =
        conn(:get, "/")
        |> put_script_name(["skills"])
        |> ToolRoutes.call(@opts)

      assert conn.status == 200
      body = decode(conn)
      assert Map.has_key?(body, "skills")
    end
  end
end
