defmodule OptimalSystemAgent.Providers.AccountToken401RecoveryTest do
  @moduledoc """
  The consumer half of the dead-token problem.

  `resolve_credential/2` refreshes on a DEADLINE. A token revoked server-side,
  or one whose clock skew put it outside the 300s window, is `false` for both
  `needs_refresh?/1` and `expired?/1` forever — so the same dead token was
  resolved, sent, 401'd, and resolved again on every single turn for the life
  of the OS process, with no path back except the user noticing.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Providers.OpenAICompatProvider, as: P

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-401recover-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    # RESTORE, do not delete. `config/test.exs` sets this to `false` for the
    # whole suite so no test can read the OPERATOR's real `~/.osa/.env` and
    # become flaky depending on whose machine runs it. Deleting the key here
    # turns that protection back ON for every test that runs afterwards.
    prev_fallback = Application.fetch_env(:optimal_system_agent, :live_env_file_fallback)
    Application.put_env(:optimal_system_agent, :live_env_file_fallback, false)

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

  defp stub_token(status, body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
  end

  defp connect_xai(access_token) do
    SubscriptionStore.put("xai", %{
      "access_token" => access_token,
      "refresh_token" => "rt-old",
      # Valid for another hour as far as the clock is concerned — so nothing
      # proactive will ever fire.
      "expires_at" => System.system_time(:second) + 3600,
      "base_url" => "https://stub.invalid/v1"
    })
  end

  describe "a 401 on an account token triggers exactly one re-resolution" do
    test "the retried call carries the RENEWED token, not the rejected one" do
      connect_xai("dead-token")
      stub_token(200, %{"access_token" => "renewed", "refresh_token" => "rt-new", "expires_in" => 3600})

      seen = :ets.new(:seen, [:public, :bag])

      result =
        P.retry_once_on_rejected_account_token(:xai, "dead-token", fn key ->
          :ets.insert(seen, {:call, key})

          if key == "dead-token" do
            {:error, "HTTP 401: {\"error\":\"invalid token\"}"}
          else
            {:ok, %{content: "worked"}}
          end
        end)

      assert result == {:ok, %{content: "worked"}}

      calls = :ets.lookup(seen, :call) |> Enum.map(fn {_, k} -> k end)

      assert calls == ["dead-token", "renewed"],
             "the request must be retried once, with the token the refresh produced"
    end

    test "it retries ONCE — a second 401 surfaces instead of looping" do
      connect_xai("dead-token")
      stub_token(200, %{"access_token" => "renewed", "refresh_token" => "rt-new", "expires_in" => 3600})

      calls = :counters.new(1, [])

      result =
        P.retry_once_on_rejected_account_token(:xai, "dead-token", fn _key ->
          :counters.add(calls, 1, 1)
          {:error, "HTTP 401: nope"}
        end)

      assert result == {:error, "HTTP 401: nope"}

      assert :counters.get(calls, 1) == 2,
             "an endlessly-401ing endpoint must not be retried endlessly"
    end
  end

  describe "what must NOT be retried" do
    test "a pasted API key's 401 surfaces unchanged" do
      # A key has nothing to refresh. Its 401 is a real "this key is wrong",
      # and swallowing it behind a refresh attempt would hide the only useful
      # diagnostic the user gets.
      calls = :counters.new(1, [])

      result =
        P.retry_once_on_rejected_account_token(:groq, "sk-pasted-key", fn _key ->
          :counters.add(calls, 1, 1)
          {:error, "HTTP 401: invalid api key"}
        end)

      assert result == {:error, "HTTP 401: invalid api key"}
      assert :counters.get(calls, 1) == 1, "a provider with no account mode must not be retried"
    end

    test "a 403 is not retried — entitlement is not a credential problem" do
      connect_xai("live-token")

      calls = :counters.new(1, [])

      result =
        P.retry_once_on_rejected_account_token(:xai, "live-token", fn _key ->
          :counters.add(calls, 1, 1)
          {:error, "HTTP 403: quota exceeded"}
        end)

      assert result == {:error, "HTTP 403: quota exceeded"}

      assert :counters.get(calls, 1) == 1,
             "refreshing an authorised-but-unentitled token changes nothing"
    end

    test "a successful call is passed straight through, untouched" do
      connect_xai("live-token")

      assert {:ok, :fine} =
               P.retry_once_on_rejected_account_token(:xai, "live-token", fn _ -> {:ok, :fine} end)
    end

    test "a rate-limit tuple is passed through rather than treated as a credential failure" do
      connect_xai("live-token")

      assert {:error, {:rate_limited, 30}} =
               P.retry_once_on_rejected_account_token(:xai, "live-token", fn _ ->
                 {:error, {:rate_limited, 30}}
               end)
    end

    test "a 401 whose refresh also fails surfaces the ORIGINAL error" do
      connect_xai("dead-token")
      # The grant is genuinely gone.
      stub_token(400, %{"error" => "invalid_grant"})

      assert {:error, "HTTP 401: nope"} =
               P.retry_once_on_rejected_account_token(:xai, "dead-token", fn _ ->
                 {:error, "HTTP 401: nope"}
               end)
    end
  end
end
