defmodule OptimalSystemAgent.Channels.HTTP.API.ModelsCurrentTest do
  @moduledoc """
  Tests for the GET /current and POST /current routes in DataRoutes,
  effective as GET /models/current and POST /models/current when called
  through the parent API router.

  Routes are tested directly against DataRoutes, with path prefix
  already stripped (same approach used in OrchestrationRoutesTest).

  Covers:
    1. GET /current returns 200 with provider, model, context_window
    2. POST /current with valid known provider+model switches and returns status=switched
    3. POST /current with missing fields returns 400
    4. POST /current with unknown provider returns 400
    5. All responses carry application/json content-type
    6. GET /current reflects Application env after a POST /current switch
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.DataRoutes

  @opts DataRoutes.init([])

  # ── Helpers ─────────────────────────────────────────────────────────

  defp call(conn), do: DataRoutes.call(conn, @opts)

  defp json_get(path) do
    conn(:get, path)
    |> call()
  end

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call()
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp content_type(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [ct | _] -> ct
      [] -> nil
    end
  end

  # Reset Application env before each test so tests are isolated.
  setup do
    original_provider = Application.get_env(:optimal_system_agent, :default_provider)
    original_model = Application.get_env(:optimal_system_agent, :default_model)
    original_ollama = Application.get_env(:optimal_system_agent, :ollama_model)

    on_exit(fn ->
      if is_nil(original_provider) do
        Application.delete_env(:optimal_system_agent, :default_provider)
      else
        Application.put_env(:optimal_system_agent, :default_provider, original_provider)
      end

      if is_nil(original_model) do
        Application.delete_env(:optimal_system_agent, :default_model)
      else
        Application.put_env(:optimal_system_agent, :default_model, original_model)
      end

      if is_nil(original_ollama) do
        Application.delete_env(:optimal_system_agent, :ollama_model)
      else
        Application.put_env(:optimal_system_agent, :ollama_model, original_ollama)
      end
    end)

    :ok
  end

  # ── GET /current ─────────────────────────────────────────────────────

  describe "GET /current" do
    test "returns 200" do
      conn = json_get("/current")
      assert conn.status == 200
    end

    test "returns application/json content-type" do
      conn = json_get("/current")
      assert content_type(conn) =~ "application/json"
    end

    test "response contains provider field" do
      conn = json_get("/current")
      body = decode(conn)
      assert Map.has_key?(body, "provider")
    end

    test "response contains model field" do
      conn = json_get("/current")
      body = decode(conn)
      assert Map.has_key?(body, "model")
    end

    test "response contains context_window field" do
      conn = json_get("/current")
      body = decode(conn)
      assert Map.has_key?(body, "context_window")
    end

    test "provider is a non-empty string" do
      conn = json_get("/current")
      body = decode(conn)
      assert is_binary(body["provider"])
      assert body["provider"] != ""
    end

    test "model is a non-empty string" do
      conn = json_get("/current")
      body = decode(conn)
      assert is_binary(body["model"])
      assert body["model"] != ""
    end

    test "reflects Application env default_provider" do
      Application.put_env(:optimal_system_agent, :default_provider, :ollama)
      Application.put_env(:optimal_system_agent, :default_model, "llama3.2:latest")

      conn = json_get("/current")
      body = decode(conn)

      assert body["provider"] == "ollama"
      assert body["model"] == "llama3.2:latest"
    end
  end

  # ── POST /current with valid known provider ───────────────────────────

  describe "POST /current with ollama provider" do
    # ollama is always present in the providers list (configured with no API key).
    # This makes it a safe provider to use in tests without external dependencies.

    test "returns 200" do
      conn = json_post("/current", %{"provider" => "ollama", "model" => "llama3.2:latest"})
      assert conn.status == 200
    end

    test "returns application/json content-type" do
      conn = json_post("/current", %{"provider" => "ollama", "model" => "llama3.2:latest"})
      assert content_type(conn) =~ "application/json"
    end

    test "response status is switched" do
      conn = json_post("/current", %{"provider" => "ollama", "model" => "llama3.2:latest"})
      body = decode(conn)
      assert body["status"] == "switched"
    end

    test "response echoes back provider" do
      conn = json_post("/current", %{"provider" => "ollama", "model" => "llama3.2:latest"})
      body = decode(conn)
      assert body["provider"] == "ollama"
    end

    test "response echoes back model" do
      conn = json_post("/current", %{"provider" => "ollama", "model" => "llama3.2:latest"})
      body = decode(conn)
      assert body["model"] == "llama3.2:latest"
    end

    test "updates Application env default_provider" do
      json_post("/current", %{"provider" => "ollama", "model" => "llama3.2:latest"})
      assert Application.get_env(:optimal_system_agent, :default_provider) == :ollama
    end

    test "updates Application env default_model" do
      json_post("/current", %{"provider" => "ollama", "model" => "llama3.2:latest"})
      assert Application.get_env(:optimal_system_agent, :default_model) == "llama3.2:latest"
    end

    test "GET /current reflects the switch immediately" do
      json_post("/current", %{"provider" => "ollama", "model" => "mistral:latest"})

      conn = json_get("/current")
      body = decode(conn)
      assert body["provider"] == "ollama"
      assert body["model"] == "mistral:latest"
    end
  end

  # ── POST /current with missing fields ────────────────────────────────

  describe "POST /current with missing fields" do
    test "returns 400 when body is empty" do
      conn = json_post("/current", %{})
      assert conn.status == 400
    end

    test "returns application/json on 400 for empty body" do
      conn = json_post("/current", %{})
      assert content_type(conn) =~ "application/json"
    end

    test "error body has error key when body is empty" do
      conn = json_post("/current", %{})
      body = decode(conn)
      assert is_binary(body["error"])
      assert body["error"] != ""
    end

    test "returns 400 when provider is missing" do
      conn = json_post("/current", %{"model" => "llama3.2:latest"})
      assert conn.status == 400
    end

    test "returns 400 when model is missing" do
      conn = json_post("/current", %{"provider" => "ollama"})
      assert conn.status == 400
    end

    test "returns 400 when provider is empty string" do
      conn = json_post("/current", %{"provider" => "", "model" => "llama3.2:latest"})
      assert conn.status == 400
    end

    test "returns 400 when model is empty string" do
      conn = json_post("/current", %{"provider" => "ollama", "model" => ""})
      assert conn.status == 400
    end
  end

  # ── POST /current with unknown provider ──────────────────────────────

  describe "POST /current with unknown provider" do
    test "returns 400" do
      conn =
        json_post("/current", %{"provider" => "nonexistent_provider_xyz", "model" => "some-model"})

      assert conn.status == 400
    end

    test "returns application/json on 400 for unknown provider" do
      conn =
        json_post("/current", %{"provider" => "nonexistent_provider_xyz", "model" => "some-model"})

      assert content_type(conn) =~ "application/json"
    end

    test "error body contains error key for unknown provider" do
      conn =
        json_post("/current", %{"provider" => "nonexistent_provider_xyz", "model" => "some-model"})

      body = decode(conn)
      assert is_binary(body["error"])
    end
  end
end
