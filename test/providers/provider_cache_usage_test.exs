defmodule OptimalSystemAgent.Providers.ProviderCacheUsageTest do
  @moduledoc """
  Cache-token accounting on the two providers that reported it and were ignored.

  Two separate defects, both silent:

    * **Bedrock** emitted `:prompt_tokens` / `:completion_tokens` /
      `:total_tokens`. `Loop.Accounting.normalize_usage/1` reads
      `:input_tokens`, `:output_tokens`, `:cache_creation_input_tokens` and
      `:cache_read_input_tokens` and NOTHING else, so every Bedrock turn
      accounted as 0 tokens and $0.00 — session cost, the `max_budget_usd` cap,
      the spend sidecar and `$/task` were all blind on the provider. It also
      dropped the Converse cache slices entirely, despite serving Anthropic
      models with the same `cache_control` support.
    * **Google** reported `cachedContentTokenCount` and OSA ignored it, so the
      cached prefix was billed at the full input rate instead of the cache-read
      rate.

  ## Verification status

  **UNVERIFIED against a live provider call.** There is no Bedrock credential
  and no Google API key on this machine. Every payload below is SYNTHETIC,
  built from the documented response shapes (Bedrock Converse `usage`, Gemini
  `usageMetadata`). What is genuinely verified is the part that broke last time:
  the key names OSA maps to, and the direction of the prompt-slice reconcile.
  The field names on the wire are the remaining risk.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Providers.Google

  describe "Google — cachedContentTokenCount is INCLUSIVE of promptTokenCount" do
    setup do
      base = 10_450
      test_pid = self()
      {server, port} = start_stub(base, test_pid, 0)

      prev_url = Application.get_env(:optimal_system_agent, :google_url)
      prev_key = Application.get_env(:optimal_system_agent, :google_api_key)
      Application.put_env(:optimal_system_agent, :google_url, "http://127.0.0.1:#{port}/v1beta")
      Application.put_env(:optimal_system_agent, :google_api_key, "not-a-real-key")

      on_exit(fn ->
        restore(:google_url, prev_url)
        restore(:google_api_key, prev_key)
        Process.exit(server, :normal)
      end)

      :ok
    end

    test "the cached slice reaches :cache_read_input_tokens" do
      assert {:ok, %{usage: usage}} =
               Google.chat([%{role: "user", content: "hi"}], model: "gemini-3.6-flash")

      # promptTokenCount 1000 is INCLUSIVE of cachedContentTokenCount 900.
      assert usage.input_tokens == 1_000
      assert usage.cache_read_input_tokens == 900
      # candidatesTokenCount 40 + thoughtsTokenCount 10.
      assert usage.output_tokens == 50
    end

    test "the overlap is reconciled out, so the cached prompt is billed once at 0.1x" do
      assert {:ok, %{usage: usage}} =
               Google.chat([%{role: "user", content: "hi"}], model: "gemini-3.6-flash")

      norm =
        usage
        |> Accounting.normalize_usage()
        |> Accounting.reconcile_prompt_slices(:google)

      # 1000 inclusive of 900 cached → 100 fresh + 900 read, each counted once.
      # Left unreconciled this would bill 1000 fresh + 900 read = the cached
      # prompt charged twice, once at full rate.
      assert norm.input_tokens == 100
      assert norm.cache_read_input_tokens == 900
      assert Accounting.effective_input_tokens(norm) == 1_000

      # gemini rate stands in for the shape; use a known-priced model so the
      # arithmetic is checkable: {$3, $15}/1M →
      # 100*3 + 900*3*0.1 + 50*15 = 300 + 270 + 750 = 1320 → $0.00132
      assert_in_delta Pricing.cost("claude-3-5-sonnet", norm), 0.00132, 0.000_001
    end

    test ":google is registered as an INCLUSIVE provider, not left to the default" do
      # The default for an unrecognised provider is "disjoint, leave alone",
      # which for Google would double-count the cached prompt. Pin that the
      # entry exists rather than trusting the list by inspection.
      norm =
        Accounting.normalize_usage(%{
          input_tokens: 500,
          cache_read_input_tokens: 500
        })

      assert Accounting.reconcile_prompt_slices(norm, :google).input_tokens == 0
    end
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp start_stub(_base, _pid, attempt) when attempt > 20 do
    flunk("could not bind a stub HTTP port after 20 attempts")
  end

  defp start_stub(base, test_pid, attempt) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.UsagePlug, test_pid},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, test_pid, attempt + 1)
    end
  end

  defmodule UsagePlug do
    @moduledoc false
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, _test_pid) do
      {:ok, _raw, conn} = read_body(conn)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}],
          "usageMetadata" => %{
            "promptTokenCount" => 1_000,
            "candidatesTokenCount" => 40,
            "thoughtsTokenCount" => 10,
            "cachedContentTokenCount" => 900
          }
        })
      )
    end
  end
end
