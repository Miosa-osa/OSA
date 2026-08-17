defmodule OptimalSystemAgent.Channels.HTTP.AuthRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.AuthRoutes
  alias OptimalSystemAgent.Channels.HTTP.Auth

  @opts AuthRoutes.init([])

  # ── Helpers ──────────────────────────────────────────────────────────

  setup do
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    original_secret = Application.get_env(:optimal_system_agent, :shared_secret)

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:optimal_system_agent, :require_auth, original_auth),
        else: Application.delete_env(:optimal_system_agent, :require_auth)

      if original_secret,
        do: Application.put_env(:optimal_system_agent, :shared_secret, original_secret),
        else: Application.delete_env(:optimal_system_agent, :shared_secret)
    end)

    :ok
  end

  defp call_routes(conn) do
    AuthRoutes.call(conn, @opts)
  end

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> call_routes()
  end

  defp json_get(path) do
    conn(:get, path)
    |> call_routes()
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  defp valid_token do
    Auth.generate_token(%{"user_id" => "test-user"})
  end

  defp valid_refresh_token do
    Auth.generate_refresh_token(%{"user_id" => "test-user"})
  end

  # ── POST /login — dev mode (no secret configured) ────────────────────

  describe "POST /login in dev mode (no shared secret)" do
    setup do
      Application.delete_env(:optimal_system_agent, :require_auth)
      Application.delete_env(:optimal_system_agent, :shared_secret)
      :ok
    end

    test "returns 200 with token and refresh_token when no secret is required" do
      conn = json_post("/login", %{user_id: "alice"})

      assert conn.status == 200
      body = decode_body(conn)
      assert is_binary(body["token"])
      assert is_binary(body["refresh_token"])
      assert body["expires_in"] == 900
    end

    test "uses the stable local identity when user_id is not provided" do
      conn = json_post("/login", %{})

      assert conn.status == 200
      body = decode_body(conn)
      assert is_binary(body["token"])
      assert {:ok, claims} = Auth.verify_token(body["token"])
      assert claims["user_id"] == "local"
    end

    test "returned token is verifiable" do
      conn = json_post("/login", %{user_id: "bob"})
      body = decode_body(conn)

      assert {:ok, claims} = Auth.verify_token(body["token"])
      assert claims["user_id"] == "bob"
    end
  end

  # ── POST /login — secret required ────────────────────────────────────

  describe "POST /login with shared_secret configured" do
    setup do
      Application.put_env(:optimal_system_agent, :shared_secret, "my-test-secret")
      Application.put_env(:optimal_system_agent, :require_auth, true)
      :ok
    end

    test "returns 200 with valid secret" do
      conn = json_post("/login", %{user_id: "alice", secret: "my-test-secret"})

      assert conn.status == 200
      body = decode_body(conn)
      assert is_binary(body["token"])
      assert is_binary(body["refresh_token"])
    end

    test "returns 401 with wrong secret" do
      conn = json_post("/login", %{user_id: "alice", secret: "wrong-secret"})

      assert conn.status == 401
      body = decode_body(conn)
      assert body["error"] == "unauthorized"
    end

    test "returns 401 with no secret field" do
      conn = json_post("/login", %{user_id: "alice"})

      assert conn.status == 401
      body = decode_body(conn)
      assert body["error"] == "unauthorized"
    end

    test "returns 401 with empty secret string" do
      conn = json_post("/login", %{user_id: "alice", secret: ""})

      assert conn.status == 401
    end
  end

  # ── POST /refresh ─────────────────────────────────────────────────────

  describe "POST /refresh" do
    test "returns 200 with new tokens when refresh token is valid" do
      conn = json_post("/refresh", %{refresh_token: valid_refresh_token()})

      assert conn.status == 200
      body = decode_body(conn)
      assert is_binary(body["token"])
      assert is_binary(body["refresh_token"])
      assert body["expires_in"] == 900
    end

    test "returns 401 when refresh token is an access token (wrong type)" do
      conn = json_post("/refresh", %{refresh_token: valid_token()})

      assert conn.status == 401
      body = decode_body(conn)
      assert body["error"] == "refresh_failed"
    end

    test "returns 401 when refresh token is completely invalid" do
      conn = json_post("/refresh", %{refresh_token: "not.a.real.token"})

      assert conn.status == 401
      body = decode_body(conn)
      assert body["error"] == "refresh_failed"
    end

    test "returns 401 when refresh_token field is empty string" do
      conn = json_post("/refresh", %{refresh_token: ""})

      assert conn.status == 401
    end

    test "returns 401 when refresh_token is missing from body" do
      conn = json_post("/refresh", %{})

      assert conn.status == 401
    end

    test "new access token from refresh is itself verifiable" do
      conn = json_post("/refresh", %{refresh_token: valid_refresh_token()})
      body = decode_body(conn)

      assert {:ok, claims} = Auth.verify_token(body["token"])
      assert claims["user_id"] == "test-user"
    end
  end

  # ── POST /logout ──────────────────────────────────────────────────────

  describe "POST /logout" do
    test "returns 200 with ok: true (stateless JWT, nothing to invalidate)" do
      conn = json_post("/logout", %{})

      assert conn.status == 200
      body = decode_body(conn)
      assert body["ok"] == true
    end
  end

  # ── Unknown auth endpoint ─────────────────────────────────────────────

  describe "unknown auth endpoint" do
    test "returns 404 for unrecognised path" do
      conn = json_get("/unknown")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "not_found"
    end
  end
end
