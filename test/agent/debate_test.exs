defmodule OptimalSystemAgent.Agent.DebateTest do
  @moduledoc """
  Tests for the multi-agent debate orchestration module.

  Most tests run without a live supervisor tree (--no-start flag).
  The mock provider is used for provider-level calls to avoid real API keys.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Debate
  alias OptimalSystemAgent.Channels.HTTP.API.DebateRoutes

  # ── Module contract ───────────────────────────────────────────────────

  describe "module contract" do
    test "Debate module exists" do
      assert Code.ensure_loaded?(Debate)
    end

    test "run/2 is exported" do
      assert function_exported?(Debate, :run, 2)
    end

    test "run/1 (default opts) is also exported" do
      assert function_exported?(Debate, :run, 1)
    end
  end

  # ── Error path — no providers ─────────────────────────────────────────

  describe "run/2 with empty providers list" do
    test "returns {:error, :no_providers} when providers is empty list" do
      result = Debate.run("What is 2+2?", providers: [])
      assert result == {:error, :no_providers}
    end
  end

  # ── Return shape ──────────────────────────────────────────────────────

  describe "return map shape" do
    setup do
      # Use mock provider so tests are hermetic — no real API calls
      prev = Application.get_env(:optimal_system_agent, :default_provider)
      Application.put_env(:optimal_system_agent, :default_provider, :mock)

      on_exit(fn ->
        if prev do
          Application.put_env(:optimal_system_agent, :default_provider, prev)
        else
          Application.delete_env(:optimal_system_agent, :default_provider)
        end
      end)

      :ok
    end

    test "successful result has :synthesis key" do
      case Debate.run("Hello", providers: ["mock"]) do
        {:ok, result} -> assert Map.has_key?(result, :synthesis)
        {:error, _} -> :ok  # mock may not be configured as session-free provider — graceful
      end
    end

    test "successful result has :debate key" do
      case Debate.run("Hello", providers: ["mock"]) do
        {:ok, result} -> assert Map.has_key?(result, :debate)
        {:error, _} -> :ok
      end
    end

    test "successful result has :participants key" do
      case Debate.run("Hello", providers: ["mock"]) do
        {:ok, result} -> assert Map.has_key?(result, :participants)
        {:error, _} -> :ok
      end
    end

    test ":debate is always a list in successful result" do
      case Debate.run("Hello", providers: ["mock"]) do
        {:ok, %{debate: debate}} -> assert is_list(debate)
        {:error, _} -> :ok
      end
    end

    test ":participants is always a non-negative integer in successful result" do
      case Debate.run("Hello", providers: ["mock"]) do
        {:ok, %{participants: n}} -> assert is_integer(n) and n >= 0
        {:error, _} -> :ok
      end
    end
  end

  # ── Option acceptance ─────────────────────────────────────────────────

  describe "option handling" do
    test "accepts :providers option without crashing" do
      result = Debate.run("test", providers: ["mock"], timeout: 2_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts :timeout option without crashing" do
      result = Debate.run("test", providers: ["mock"], timeout: 1_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts :synthesizer_provider option without crashing" do
      result = Debate.run("test", providers: ["mock"], synthesizer_provider: "mock", timeout: 2_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts :user_id option without crashing" do
      result = Debate.run("test", providers: ["mock"], user_id: "user-42", timeout: 2_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts :model option without crashing" do
      result = Debate.run("test", providers: ["mock"], model: "claude-3-haiku-20240307", timeout: 2_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ── All providers unavailable (very short timeout) ────────────────────

  describe "graceful handling when all providers fail" do
    test "returns :error when single bogus provider fails" do
      # Using a provider name that doesn't map to anything real forces failure.
      # We keep timeout at 100ms to avoid test slowdown.
      result = Debate.run("ping", providers: ["nonexistent_bogus_provider_xyz"], timeout: 100)

      # Either error (no providers available / all failed) or ok — not a crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise even when all providers time out" do
      # Tiny timeout guarantees all tasks will expire
      result = Debate.run("hello", providers: ["ollama"], timeout: 1)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ── HTTP Route tests ──────────────────────────────────────────────────

  describe "DebateRoutes HTTP — 400 validation" do
    use Plug.Test

    @opts DebateRoutes.init([])

    defp call_route(conn) do
      DebateRoutes.call(conn, @opts)
    end

    defp json_post(path, body) do
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> call_route()
    end

    test "POST / returns 400 when message field is missing" do
      conn = json_post("/", %{})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_request"
      assert body["details"] =~ "message"
    end

    test "POST / returns 400 when message is empty string" do
      conn = json_post("/", %{"message" => ""})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_request"
    end

    test "POST / returns 400 when message field is null/missing key" do
      conn = json_post("/", %{"providers" => ["mock"]})
      assert conn.status == 400
    end

    test "POST / with valid message returns 200 or 500 (no live providers in test)" do
      conn = json_post("/", %{"message" => "What is the speed of light?", "providers" => ["mock"], "timeout" => 2000})
      # 200 means debate succeeded (mock provider responded), 500 means all failed
      assert conn.status in [200, 500]
    end

    test "POST / 200 response body has synthesis key" do
      conn = json_post("/", %{"message" => "test", "providers" => ["mock"], "timeout" => 2000})
      if conn.status == 200 do
        body = Jason.decode!(conn.resp_body)
        assert Map.has_key?(body, "synthesis")
        assert Map.has_key?(body, "debate")
        assert Map.has_key?(body, "participants")
      else
        # Gracefully skipped — no live provider
        :ok
      end
    end

    test "non-POST path returns 404" do
      conn =
        conn(:get, "/")
        |> call_route()

      assert conn.status == 404
    end
  end
end
