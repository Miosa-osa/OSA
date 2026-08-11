defmodule OptimalSystemAgent.Providers.CredentialPoolRateLimitTest do
  @moduledoc """
  Defect 4 — `CredentialPool.mark_rate_limited/2` had ZERO callers.

  The module's own docs promise "round-robin rotation and automatic skip of
  rate-limited keys", and `find_available_key/5` implements the skip. Nothing
  ever put a key into the rate-limited state, so the skip could never fire: a
  key that returned HTTP 429 was handed straight back out on the next attempt,
  and every same-provider retry (`Resilience.with_retry` runs those BEFORE any
  fallback) burned on the same throttled key. Key rotation was dead code.

  The wiring point is the 429 recognition site in `Providers.Anthropic` — the
  only caller of `get_key/1`, and upstream of the retry loop, which is what
  makes the *next* attempt pick a different key.

  NOTE: there is no live Anthropic key on this machine. The 429 is served by a
  local Bandit stub, so the wiring is verified but not exercised against the
  real Anthropic API.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Anthropic
  alias OptimalSystemAgent.Providers.CredentialPool

  @key_a "sk-ant-pool-AAAA0001"
  @key_b "sk-ant-pool-BBBB0002"

  setup do
    prev_keys = System.get_env("ANTHROPIC_API_KEYS")
    prev_single = System.get_env("ANTHROPIC_API_KEY")
    prev_app_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)

    System.put_env("ANTHROPIC_API_KEYS", "#{@key_a},#{@key_b}")
    System.delete_env("ANTHROPIC_API_KEY")
    :ok = CredentialPool.reload()

    on_exit(fn ->
      restore_env("ANTHROPIC_API_KEYS", prev_keys)
      restore_env("ANTHROPIC_API_KEY", prev_single)

      case prev_app_key do
        nil -> Application.delete_env(:optimal_system_agent, :anthropic_api_key)
        v -> Application.put_env(:optimal_system_agent, :anthropic_api_key, v)
      end

      CredentialPool.reload()
    end)

    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, val), do: System.put_env(name, val)

  describe "pool state" do
    test "a two-key pool round-robins while both keys are healthy" do
      assert CredentialPool.get_key(:anthropic) == @key_a
      assert CredentialPool.get_key(:anthropic) == @key_b
      assert CredentialPool.get_key(:anthropic) == @key_a
      assert %{total: 2, available: 2, rate_limited: 0} = CredentialPool.stats(:anthropic)
    end

    test "marking the last-issued key takes it out of rotation" do
      assert CredentialPool.get_key(:anthropic) == @key_a

      :ok = CredentialPool.mark_rate_limited(:anthropic)

      # `stats/1` is a call — it flushes the cast that precedes it.
      assert %{total: 2, available: 1, rate_limited: 1} = CredentialPool.stats(:anthropic)

      # The throttled key is skipped on every subsequent selection, not just the
      # next one (the whole point: a retry must not land on it again).
      assert CredentialPool.get_key(:anthropic) == @key_b
      assert CredentialPool.get_key(:anthropic) == @key_b
      assert CredentialPool.get_key(:anthropic) == @key_b
    end
  end

  describe "the 429 path actually marks the credential" do
    setup do
      base = String.to_integer(System.get_env("OSA_HTTP_PORT") || "10731")
      {server, port} = start_stub(base, 0)

      prev_url = Application.get_env(:optimal_system_agent, :anthropic_url)
      Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:#{port}/v1")

      on_exit(fn ->
        case prev_url do
          nil -> Application.delete_env(:optimal_system_agent, :anthropic_url)
          v -> Application.put_env(:optimal_system_agent, :anthropic_url, v)
        end

        if Process.alive?(server), do: Process.exit(server, :normal)
      end)

      :ok
    end

    test "an HTTP 429 marks the key that was used, and the NEXT selection avoids it" do
      # Precondition: the pool is clean and the next key out is A.
      assert %{rate_limited: 0} = CredentialPool.stats(:anthropic)

      assert {:error, {:rate_limited, _retry_after}} =
               Anthropic.chat([%{role: "user", content: "hi"}], model: "claude-opus-5")

      assert %{total: 2, available: 1, rate_limited: 1} = CredentialPool.stats(:anthropic),
             "the 429 did not mark the credential — mark_rate_limited/2 still has no caller"

      # The key the throttled request used must not come back out.
      assert CredentialPool.get_key(:anthropic) == @key_b
      assert CredentialPool.get_key(:anthropic) == @key_b
    end

    test "a streaming 429 marks the credential too" do
      assert %{rate_limited: 0} = CredentialPool.stats(:anthropic)

      assert {:error, {:rate_limited, _}} =
               Anthropic.chat_stream(
                 [%{role: "user", content: "hi"}],
                 fn _ -> :ok end,
                 model: "claude-opus-5"
               )

      assert %{rate_limited: 1} = CredentialPool.stats(:anthropic),
             "the streaming 429 path is unwired"
    end
  end

  defp start_stub(_base, attempt) when attempt > 20 do
    flunk("could not bind a stub HTTP port after 20 attempts")
  end

  defp start_stub(base, attempt) do
    port = base + attempt

    # Probe first: Bandit.start_link/1 LINKS, so an :eaddrinuse would kill the
    # test process instead of returning {:error, _}.
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: __MODULE__.RateLimitPlug,
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, attempt + 1)
    end
  end

  defmodule RateLimitPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _raw, conn} = read_body(conn)

      conn
      |> put_resp_header("retry-after", "42")
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        Jason.encode!(%{"error" => %{"type" => "rate_limit_error", "message" => "slow down"}})
      )
    end
  end
end
