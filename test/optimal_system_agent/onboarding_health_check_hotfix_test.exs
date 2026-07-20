defmodule OptimalSystemAgent.OnboardingHealthCheckHotfixTest do
  @moduledoc """
  Regression coverage for the onboarding health-check hotfix:

    * `health_check/1` now stamps every result with a `verified:` tag —
      `:ok`, `:key_rejected` (explicit 401/403/insufficient_credits only),
      or `:unverified` (transport error, timeout, non-auth 4xx/5xx). A
      transport/HTTP error must NEVER be reported as `:key_rejected`.
    * `ollama_cloud` verifies against a reachable LOCAL Ollama daemon first
      (the actual keyless device-identity runtime path) — a Bearer-token
      mismatch against `https://ollama.com` must not fail an otherwise
      working local setup. Only when no local daemon is reachable does a
      supplied key get verified against `ollama.com`.

  All HTTP is intercepted via `Req.Test` (`plug: {Req.Test, name}` passed
  through `params["req_plug"]`) — no real network calls, fully offline and
  deterministic. Uses a per-test unique stub name so tests can run `async:
  true` without cross-talk.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Onboarding

  defp stub_name(tag), do: :"onboarding_hc_#{tag}_#{System.unique_integer([:positive])}"

  # ── Generic classification (non-ollama_cloud provider) ───────────────────

  describe "health_check/1 — three-way classification" do
    test "2xx -> {:ok, %{verified: :ok}}" do
      name = stub_name(:ok)

      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{"choices" => []})
      end)

      assert {:ok, %{verified: :ok, status: "ok"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk-test",
                 "model" => "gpt-4o",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "401 -> {:error, %{verified: :key_rejected, error: \"unauthorized\"}}" do
      name = stub_name(:e401)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

      assert {:error, %{verified: :key_rejected, error: "unauthorized"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "bad",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "402 -> {:error, %{verified: :key_rejected, error: \"insufficient_credits\"}}" do
      name = stub_name(:e402)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 402, "") end)

      assert {:error, %{verified: :key_rejected, error: "insufficient_credits"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "403 -> {:error, %{verified: :key_rejected, error: \"forbidden\"}}" do
      name = stub_name(:e403)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)

      assert {:error, %{verified: :key_rejected, error: "forbidden"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "404 (model not found) -> UNVERIFIED, not key_rejected" do
      name = stub_name(:e404)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, %{verified: :unverified, error: "model_not_found"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk",
                 "model" => "ghost-model",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "non-auth 5xx -> UNVERIFIED, not key_rejected" do
      name = stub_name(:e500)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, %{verified: :unverified, error: "server_error"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "transport error (connection refused) -> UNVERIFIED, not key_rejected" do
      name = stub_name(:econnrefused)

      Req.Test.stub(name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %{verified: :unverified, error: "connection_refused"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk-perfectly-fine",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "transport error (timeout) -> UNVERIFIED, never reported as an invalid key" do
      name = stub_name(:timeout)
      Req.Test.stub(name, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %{verified: :unverified, error: "timeout"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk-perfectly-fine",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "429 rate-limited is still a success (key works)" do
      name = stub_name(:e429)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

      assert {:ok, %{verified: :ok, warning: "rate_limited"}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk",
                 "req_plug" => {Req.Test, name}
               })
    end
  end

  # ── ollama_cloud: local-daemon-first routing (the actual hotfix bug) ─────

  describe "health_check/1 for ollama_cloud — local daemon takes priority over Bearer" do
    test "local daemon reachable -> verifies against it and succeeds, even with a key typed that would fail against ollama.com" do
      name = stub_name(:ollama_local_ok)

      Req.Test.stub(name, fn conn ->
        case {conn.host, conn.request_path} do
          {"localhost", "/api/tags"} ->
            Req.Test.json(conn, %{"models" => [%{"name" => "glm-5.2:cloud"}]})

          {"localhost", "/api/chat"} ->
            Req.Test.json(conn, %{"message" => %{"content" => "hi"}})

          # Must NEVER be hit: the key is garbage and would 401 on ollama.com,
          # but the local daemon is reachable so that path must not be tried.
          {"ollama.com", _} ->
            Plug.Conn.send_resp(conn, 401, "")
        end
      end)

      assert {:ok, %{verified: :ok}} =
               Onboarding.health_check(%{
                 "provider" => "ollama_cloud",
                 "api_key" => "this-key-would-fail-on-ollama-dot-com",
                 "model" => "glm-5.2:cloud",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "no local daemon, key supplied and rejected -> key_rejected via ollama.com" do
      name = stub_name(:ollama_cloud_rejected)

      Req.Test.stub(name, fn conn ->
        case conn.request_path do
          "/api/tags" -> Plug.Conn.send_resp(conn, 502, "")
          "/api/chat" -> Plug.Conn.send_resp(conn, 401, "")
        end
      end)

      assert {:error, %{verified: :key_rejected, error: "unauthorized"}} =
               Onboarding.health_check(%{
                 "provider" => "ollama_cloud",
                 "api_key" => "bad-key",
                 "model" => "glm-5.2:cloud",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "no local daemon, key supplied, ollama.com transport error -> UNVERIFIED, never key_rejected" do
      name = stub_name(:ollama_cloud_transport)

      Req.Test.stub(name, fn conn ->
        case conn.request_path do
          "/api/tags" -> Plug.Conn.send_resp(conn, 502, "")
          "/api/chat" -> Req.Test.transport_error(conn, :timeout)
        end
      end)

      assert {:error, %{verified: :unverified}} =
               Onboarding.health_check(%{
                 "provider" => "ollama_cloud",
                 "api_key" => "probably-fine-key",
                 "model" => "glm-5.2:cloud",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "no local daemon, no key -> non-blocking UNVERIFIED (not a key rejection)" do
      name = stub_name(:ollama_cloud_nokey)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 502, "") end)

      assert {:error, %{verified: :unverified, error: "no_local_daemon"}} =
               Onboarding.health_check(%{
                 "provider" => "ollama_cloud",
                 "api_key" => nil,
                 "model" => "glm-5.2:cloud",
                 "req_plug" => {Req.Test, name}
               })
    end
  end

  describe "probe_ollama_local/1 accepts injectable req_opts (testability)" do
    test "reports reachable: true when the stub returns a models list" do
      name = stub_name(:probe_ok)
      Req.Test.stub(name, fn conn -> Req.Test.json(conn, %{"models" => [%{"name" => "a"}]}) end)

      assert %{reachable: true, model_count: 1} =
               Onboarding.probe_ollama_local(plug: {Req.Test, name}, retry: false)
    end

    test "reports reachable: false on a transport error, never raises" do
      name = stub_name(:probe_down)
      Req.Test.stub(name, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert %{reachable: false} =
               Onboarding.probe_ollama_local(plug: {Req.Test, name}, retry: false)
    end

    test "probe_ollama_local/0 (arity-0, back-compat) still works" do
      result = Onboarding.probe_ollama_local()
      assert is_boolean(result.reachable)
    end
  end
end
