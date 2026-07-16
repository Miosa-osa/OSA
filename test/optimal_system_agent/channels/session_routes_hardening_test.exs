defmodule OptimalSystemAgent.Channels.SessionRoutesHardeningTest do
  @moduledoc """
  Regression tests for the defensive input hardening on the session sub-router.

  Each of these routes previously used `unless <cond> do ...send_resp(400)...
  |> halt() end` with NO else clause. Because `halt/1` in a Plug.Router route
  body only sets conn.halted — it does NOT return — execution fell through the
  success path on invalid input and either raised (Enum over nil, String.capitalize
  on nil) or sent a SECOND response on an already-sent conn
  (Plug.Conn.AlreadySentError), killing the connection with a 500.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes

  @opts SessionRoutes.init([])

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> SessionRoutes.call(@opts)
  end

  describe "POST /:id/survey/answer (finding 1)" do
    test "empty body returns a clean 400, not a crash" do
      conn = json_post("/abc/survey/answer", %{})
      assert conn.status == 400
      assert conn.state == :sent
    end

    test "answers as a non-list (string) returns 400 instead of raising" do
      conn = json_post("/abc/survey/answer", %{"survey_id" => "s1", "answers" => "foo"})
      assert conn.status == 400
    end

    test "answers as an object returns 400 instead of raising" do
      conn = json_post("/abc/survey/answer", %{"survey_id" => "s1", "answers" => %{"a" => 1}})
      assert conn.status == 400
    end

    test "missing survey_id returns 400" do
      conn = json_post("/abc/survey/answer", %{"answers" => []})
      assert conn.status == 400
    end
  end

  describe "POST /:id/survey/skip (finding 3)" do
    test "empty body returns a clean 400, not a crash" do
      conn = json_post("/abc/survey/skip", %{})
      assert conn.status == 400
      assert conn.state == :sent
    end

    test "valid survey_id still returns 200 skipped" do
      conn = json_post("/abc/survey/skip", %{"survey_id" => "s1"})
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "skipped"
    end
  end

  describe "POST /:id/message (finding 2)" do
    test "empty body returns a clean 400, not a second-response crash" do
      conn = json_post("/abc/message", %{})
      assert conn.status == 400
      assert conn.state == :sent
    end

    test "null message returns 400" do
      conn = json_post("/abc/message", %{"message" => nil})
      assert conn.status == 400
    end

    test "non-string message returns 400 instead of falling through" do
      conn = json_post("/abc/message", %{"message" => 123})
      assert conn.status == 400
    end

    test "empty-string message returns 400" do
      conn = json_post("/abc/message", %{"message" => ""})
      assert conn.status == 400
    end
  end
end
