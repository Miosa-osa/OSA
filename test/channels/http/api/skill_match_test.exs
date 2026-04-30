defmodule OptimalSystemAgent.Channels.HTTP.API.SkillMatchTest do
  @moduledoc """
  Tests for the POST /skills/match endpoint (dry-run skill matching).

  The endpoint returns which skills would be triggered for a given message
  without actually running any agent. It lives in ToolRoutes, which is
  forwarded to from the /skills prefix.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes
  alias OptimalSystemAgent.Tools.Registry

  @opts ToolRoutes.init([])
  @suffix System.unique_integer([:positive]) |> Integer.to_string()

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> ToolRoutes.call(@opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp seed_skill(name, triggers, description \\ "Test match skill") do
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

  # ── POST /match — validation ─────────────────────────────────────────────────

  describe "POST /match — input validation" do
    test "returns 400 when message field is missing" do
      conn = json_post("/match", %{})

      assert conn.status == 400
      body = decode(conn)
      assert body["error"] == "missing_message"
    end

    test "returns 400 when message is empty string" do
      conn = json_post("/match", %{"message" => ""})

      assert conn.status == 400
      body = decode(conn)
      assert body["error"] == "missing_message"
    end

    test "returns 400 when message is null" do
      conn = json_post("/match", %{"message" => nil})

      assert conn.status == 400
      body = decode(conn)
      assert body["error"] == "missing_message"
    end

    test "returns 400 when message is an integer" do
      conn = json_post("/match", %{"message" => 42})

      assert conn.status == 400
      body = decode(conn)
      assert body["error"] == "missing_message"
    end
  end

  # ── POST /match — response structure ────────────────────────────────────────

  describe "POST /match — response structure" do
    test "returns 200 with expected keys for a valid message" do
      conn = json_post("/match", %{"message" => "any message at all"})

      assert conn.status == 200
      body = decode(conn)
      assert Map.has_key?(body, "message_preview")
      assert Map.has_key?(body, "matched_count")
      assert Map.has_key?(body, "skills")
      assert is_integer(body["matched_count"])
      assert is_list(body["skills"])
    end

    test "matched_count equals length of skills list" do
      conn = json_post("/match", %{"message" => "nothing specific here"})

      assert conn.status == 200
      body = decode(conn)
      assert body["matched_count"] == length(body["skills"])
    end

    test "message_preview is included in response" do
      conn = json_post("/match", %{"message" => "deploy the service"})

      assert conn.status == 200
      body = decode(conn)
      assert is_binary(body["message_preview"])
      assert String.length(body["message_preview"]) > 0
    end

    test "message_preview is truncated to 120 chars for very long messages" do
      long_msg = String.duplicate("deploy service now ", 30)
      conn = json_post("/match", %{"message" => long_msg})

      assert conn.status == 200
      body = decode(conn)
      assert String.length(body["message_preview"]) <= 120
    end
  end

  # ── POST /match — skill matching ─────────────────────────────────────────────

  describe "POST /match — skill matching behavior" do
    setup do
      name = "match-endpoint-skill-#{@suffix}"
      seed_skill(name, ["matchkeyword#{@suffix}"], "Skill matched by endpoint test")
      on_exit(fn -> cleanup_skill(name) end)
      {:ok, skill_name: name}
    end

    test "returns matched skill when trigger keyword is in message", %{skill_name: name} do
      conn = json_post("/match", %{"message" => "please matchkeyword#{@suffix} this request"})

      assert conn.status == 200
      body = decode(conn)
      matched_names = Enum.map(body["skills"], fn s -> s["name"] end)
      assert name in matched_names
      assert body["matched_count"] >= 1
    end

    test "returns zero matches when message has no trigger keyword", %{skill_name: name} do
      conn = json_post("/match", %{"message" => "completely unrelated request with no trigger"})

      assert conn.status == 200
      body = decode(conn)
      matched_names = Enum.map(body["skills"], fn s -> s["name"] end)
      refute name in matched_names
    end

    test "each matched skill entry has name, description, triggers, has_instructions fields", %{
      skill_name: name
    } do
      conn = json_post("/match", %{"message" => "matchkeyword#{@suffix} something"})

      assert conn.status == 200
      body = decode(conn)
      skill = Enum.find(body["skills"], fn s -> s["name"] == name end)
      assert skill != nil
      assert Map.has_key?(skill, "name")
      assert Map.has_key?(skill, "description")
      assert Map.has_key?(skill, "triggers")
      assert Map.has_key?(skill, "has_instructions")
      assert is_boolean(skill["has_instructions"])
    end

    test "has_instructions is true when skill has non-empty instructions", %{skill_name: name} do
      conn = json_post("/match", %{"message" => "matchkeyword#{@suffix}"})

      assert conn.status == 200
      body = decode(conn)
      skill = Enum.find(body["skills"], fn s -> s["name"] == name end)
      assert skill["has_instructions"] == true
    end

    test "triggers list is returned in skill entry", %{skill_name: name} do
      conn = json_post("/match", %{"message" => "matchkeyword#{@suffix}"})

      assert conn.status == 200
      body = decode(conn)
      skill = Enum.find(body["skills"], fn s -> s["name"] == name end)
      assert is_list(skill["triggers"])
      assert "matchkeyword#{@suffix}" in skill["triggers"]
    end

    test "no agent is spawned — response is synchronous and immediate" do
      # The endpoint must return without starting any GenServer or async work.
      # We verify this by checking the response is 200 with a skills field,
      # and that no :processing status is returned (which would indicate async dispatch).
      conn = json_post("/match", %{"message" => "matchkeyword#{@suffix} query"})

      assert conn.status == 200
      body = decode(conn)
      refute Map.has_key?(body, "status")
      refute Map.has_key?(body, "session_id")
      assert Map.has_key?(body, "skills")
    end
  end

  # ── POST /match — multiple skills ──────────────────────────────────────────

  describe "POST /match — multiple skills can match" do
    setup do
      name_a = "multi-skill-a-#{@suffix}"
      name_b = "multi-skill-b-#{@suffix}"
      seed_skill(name_a, ["multimatch#{@suffix}"])
      seed_skill(name_b, ["multimatch#{@suffix}"])

      on_exit(fn ->
        cleanup_skill(name_a)
        cleanup_skill(name_b)
      end)

      {:ok, name_a: name_a, name_b: name_b}
    end

    test "returns both skills when both trigger on the same keyword", %{name_a: a, name_b: b} do
      conn = json_post("/match", %{"message" => "multimatch#{@suffix} the thing"})

      assert conn.status == 200
      body = decode(conn)
      matched_names = Enum.map(body["skills"], fn s -> s["name"] end)
      assert a in matched_names
      assert b in matched_names
      assert body["matched_count"] >= 2
    end
  end
end
