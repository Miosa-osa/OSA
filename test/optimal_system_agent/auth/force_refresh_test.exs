defmodule OptimalSystemAgent.Auth.ForceRefreshTest do
  @moduledoc """
  Recovery from a token the SERVER rejected but the CLIENT still believes in.

  Every provider's proactive refresh is deadline arithmetic — `needs_refresh?/1`
  and `expired?/1` compare `expires_at` against the clock. A deadline is not
  the only way a token dies: a clock skewed past the 300s window, or a
  provider-side revocation, leaves both predicates answering `false` forever.

  Before this, `xai`, `qwen` and `minimax` had no `force_refresh/1` at all and
  their shared consumer took the token once and never re-resolved on a 401, so
  the dead token was handed out on every turn for the life of the OS process
  and the only recovery was for the user to notice and re-run sign-in.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.Providers.MiniMax
  alias OptimalSystemAgent.Auth.Providers.Qwen
  alias OptimalSystemAgent.Auth.Providers.XAI
  alias OptimalSystemAgent.Auth.RefreshFailures
  alias OptimalSystemAgent.Auth.SubscriptionStore

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-forcerefresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    # A stray `.env` must not be able to hand these tests an API key and
    # quietly flip every assertion onto the key path.
    #
    # RESTORE, do not delete: `config/test.exs` sets this `false` suite-wide
    # so no test reads the OPERATOR's real `~/.osa/.env`. Deleting the key
    # re-enables that fallback for every test that runs after this one.
    prev_fallback = Application.fetch_env(:optimal_system_agent, :live_env_file_fallback)
    Application.put_env(:optimal_system_agent, :live_env_file_fallback, false)

    for id <- ~w(xai qwen minimax), do: RefreshFailures.reset(id)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      Application.delete_env(:optimal_system_agent, :auth_req_options)

      case prev_fallback do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :live_env_file_fallback, v)
        :error -> Application.delete_env(:optimal_system_agent, :live_env_file_fallback)
      end

      File.rm_rf(dir)
    end)

    :ok
  end

  # Answer every token request with one scripted body, whatever the host.
  defp stub(status, body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
    :ok
  end

  defp explode(message) do
    Application.put_env(:optimal_system_agent, :auth_req_options,
      plug: fn _ -> raise message end,
      retry: false
    )
  end

  # An hour of validity left by the clock's reckoning — so the proactive path
  # has no reason to act, which is precisely the situation that stranded the
  # user before.
  defp seed(provider_id, access_token) do
    SubscriptionStore.put(provider_id, %{
      "access_token" => access_token,
      "refresh_token" => "rt-old",
      "expires_at" => System.system_time(:second) + 3600,
      "base_url" => "https://stub.invalid/v1",
      "portal_base_url" => "https://stub.invalid"
    })
  end

  describe "the three providers that previously had no recovery path at all" do
    test "xai force_refresh/1 renews a token the server rejected though it had not expired" do
      seed("xai", "rejected")

      refute XAI.needs_refresh?(SubscriptionStore.fetch("xai")),
             "the proactive path has no reason to act here, which is the whole problem"

      stub(200, %{"access_token" => "renewed", "refresh_token" => "rt-new", "expires_in" => 3600})

      assert {:ok, "renewed"} = XAI.force_refresh("rejected")
      assert SubscriptionStore.fetch("xai")["access_token"] == "renewed"
    end

    test "qwen force_refresh/1 renews a token the server rejected though it had not expired" do
      seed("qwen", "rejected")
      refute Qwen.needs_refresh?(SubscriptionStore.fetch("qwen"))

      stub(200, %{"access_token" => "renewed", "refresh_token" => "rt-new", "expires_in" => 3600})

      assert {:ok, "renewed"} = Qwen.force_refresh("rejected")
      assert SubscriptionStore.fetch("qwen")["access_token"] == "renewed"
    end

    test "minimax force_refresh/1 renews a token the server rejected though it had not expired" do
      seed("minimax", "rejected")
      refute MiniMax.needs_refresh?(SubscriptionStore.fetch("minimax"))

      stub(200, %{
        "status" => "success",
        "access_token" => "renewed",
        "refresh_token" => "rt-new",
        "expired_in" => 3600
      })

      assert {:ok, "renewed"} = MiniMax.force_refresh("rejected")
      assert SubscriptionStore.fetch("minimax")["access_token"] == "renewed"
    end
  end

  describe "a peer that already rotated is adopted, never double-spent" do
    # Refresh tokens are single-use. If this dialled out after a peer process
    # had already rotated the credential, the exchange would present an
    # already-spent token and the provider would invalidate the whole grant —
    # the user is silently signed out and the only symptom is a 401.
    test "xai" do
      seed("xai", "already-rotated-by-a-peer")
      explode("must not spend a refresh token that a peer already rotated")

      assert {:ok, "already-rotated-by-a-peer"} = XAI.force_refresh("rejected")
    end

    test "qwen" do
      seed("qwen", "already-rotated-by-a-peer")
      explode("must not spend a refresh token that a peer already rotated")

      assert {:ok, "already-rotated-by-a-peer"} = Qwen.force_refresh("rejected")
    end

    test "minimax" do
      seed("minimax", "already-rotated-by-a-peer")
      explode("must not spend a refresh token that a peer already rotated")

      assert {:ok, "already-rotated-by-a-peer"} = MiniMax.force_refresh("rejected")
    end
  end

  describe "an unconnected provider reports itself rather than crashing" do
    test "all three" do
      assert {:error, :not_connected} = XAI.force_refresh("anything")
      assert {:error, :not_connected} = Qwen.force_refresh("anything")
      assert {:error, :not_connected} = MiniMax.force_refresh("anything")
    end
  end

  describe "force_refresh is exported by every account-mode provider" do
    # `Copilot.force_refresh/1` sat with ZERO callers — a recovery path that
    # existed and could never run. The consumer now calls this on a 401, so
    # every provider it can resolve a credential for has to have it.
    test "every module in the account-mode table exports force_refresh/1" do
      for provider <- OptimalSystemAgent.Providers.OpenAICompatProvider.account_mode_providers() do
        module = OptimalSystemAgent.Providers.OpenAICompatProvider.account_mode_module(provider)

        assert function_exported?(module, :force_refresh, 1),
               "#{inspect(module)} is resolved for account credentials but cannot recover from a 401"
      end
    end
  end
end
