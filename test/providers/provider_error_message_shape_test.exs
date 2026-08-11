defmodule OptimalSystemAgent.Providers.ProviderErrorMessageShapeTest do
  @moduledoc """
  A structured provider error must not crash the code whose only job is to
  explain it.

  Every provider transport pattern-matched `%{"error" => %{"message" => msg}}`
  and returned `msg` with no `is_binary/1` guard, then interpolated the result
  into the error string it hands back (`"HTTP 400: \#{error_msg}"`). Gateways
  routinely answer with a nested object or a list of validation entries under
  `message` — FastAPI-style `[{loc, msg, type}]` is the common one — and
  interpolating that raises `Protocol.UndefinedError`.

  The blast radius is not a bad log line: the raise is swallowed by each
  provider's outer `rescue`, so what reaches `ErrorCatalog` and the fallback
  chain is a generic "unexpected error" with the HTTP status and the provider's
  own explanation both destroyed. A classifiable 400 became an unclassifiable
  crash.

  These tests drive the real transports against a local stub, so they pin the
  behaviour at the seam the agent loop actually sees.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.{Anthropic, Cohere, Google, OpenAICompat}

  @port_base 22_300

  # A `message` that is NOT a string. Both shapes are real: the nested object is
  # what several OpenAI-compatible gateways emit, the list is FastAPI/pydantic
  # validation output passed through verbatim.
  @nested_message %{"detail" => "model is not available on this plan", "param" => "model"}
  @list_message [
    %{"loc" => ["body", "messages", 0], "msg" => "field required", "type" => "value_error"}
  ]

  setup do
    Code.ensure_loaded!(Anthropic)
    Code.ensure_loaded!(Google)
    Code.ensure_loaded!(Cohere)

    {:ok, agent} = Agent.start_link(fn -> @nested_message end)

    window = @port_base + rem(System.unique_integer([:positive]), 200) * 2
    {srv, port} = start_stub(window, agent, 0)

    prev =
      snapshot([
        :anthropic_url,
        :anthropic_api_key,
        :google_url,
        :google_api_key,
        :cohere_url,
        :cohere_api_key
      ])

    base = "http://127.0.0.1:#{port}"
    put(:anthropic_url, base <> "/v1")
    put(:anthropic_api_key, "sk-ant-test-not-a-real-key")
    put(:google_url, base)
    put(:google_api_key, "test-not-a-real-key")
    put(:cohere_url, base)
    put(:cohere_api_key, "test-not-a-real-key")

    on_exit(fn ->
      restore_all(prev)
      Process.exit(srv, :kill)
    end)

    {:ok, agent: agent, base: base}
  end

  defp set_message(agent, shape), do: Agent.update(agent, fn _ -> shape end)

  # The signature of the bug: the outer `rescue` in each provider turns the
  # Protocol.UndefinedError into an "unexpected error" string, and the status
  # code plus the provider's own explanation are gone.
  defp assert_classifiable(result, status_marker) do
    assert {:error, msg} = result
    assert is_binary(msg)

    refute msg =~ "unexpected error",
           "the error explainer crashed and the outer rescue swallowed it: #{msg}"

    refute msg =~ "Unexpected error", "the error explainer crashed: #{msg}"

    refute msg =~ "protocol String.Chars",
           "a non-binary message reached a string interpolation: #{msg}"

    assert msg =~ status_marker,
           "the HTTP status must survive so ErrorCatalog can classify it: #{msg}"
  end

  describe "OpenAICompat.chat/5 with a non-binary error message" do
    test "nested object", %{agent: a, base: base} do
      set_message(a, @nested_message)

      OpenAICompat.chat(base <> "/v1", "sk-test-not-a-real-key", "m", msgs(), [])
      |> assert_classifiable("400")
    end

    test "validation list", %{agent: a, base: base} do
      set_message(a, @list_message)

      OpenAICompat.chat(base <> "/v1", "sk-test-not-a-real-key", "m", msgs(), [])
      |> assert_classifiable("400")
    end
  end

  describe "Anthropic.chat/2 with a non-binary error message" do
    test "nested object", %{agent: a} do
      set_message(a, @nested_message)
      assert_classifiable(Anthropic.chat(msgs(), max_tokens: 16), "400")
    end
  end

  describe "Google.chat/2 with a non-binary error message" do
    test "nested object", %{agent: a} do
      set_message(a, @nested_message)
      assert_classifiable(Google.chat(msgs(), max_tokens: 16), "400")
    end
  end

  describe "Cohere.chat/2 with a non-binary error message" do
    test "nested object", %{agent: a} do
      set_message(a, @nested_message)
      assert_classifiable(Cohere.chat(msgs(), max_tokens: 16), "400")
    end
  end

  defp msgs, do: [%{role: "user", content: "hello"}]

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp put(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp snapshot(keys),
    do: Map.new(keys, fn k -> {k, Application.fetch_env(:optimal_system_agent, k)} end)

  defp restore_all(prev) do
    Enum.each(prev, fn
      {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
      {k, :error} -> Application.delete_env(:optimal_system_agent, k)
    end)
  end

  defp start_stub(_base, _agent, attempt) when attempt > 20,
    do: flunk("could not bind a stub HTTP port after 20 attempts")

  defp start_stub(base, agent, attempt) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.StubPlug, agent},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, agent, attempt + 1)
    end
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, _raw, conn} = read_body(conn)
      message = Agent.get(agent, & &1)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{"error" => %{"message" => message}}))
    end
  end
end
