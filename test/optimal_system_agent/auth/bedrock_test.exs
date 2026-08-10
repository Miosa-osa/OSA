defmodule OptimalSystemAgent.Auth.Providers.BedrockTest do
  @moduledoc """
  Amazon Bedrock's account mode.

  Two invariants dominate this file, because both are the kind of thing that
  is easy to break in a refactor and impossible to notice afterwards:

    * **OSA must never store an AWS secret.** The connection marker records
      where a credential came from, not the credential. A regression here
      would leak an entire cloud account's key into a second file that
      survives rotation.
    * **A status check must never cost a metered request.** Verification uses
      the control plane, which is free; `/invoke` is not.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.Providers.Bedrock
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore

  @env ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
          AWS_REGION AWS_DEFAULT_REGION AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
          AWS_BEARER_TOKEN_BEDROCK)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    dir = Path.join(System.tmp_dir!(), "osa-bedrock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)
    System.put_env("AWS_SHARED_CREDENTIALS_FILE", Path.join(dir, "credentials"))
    System.put_env("AWS_CONFIG_FILE", Path.join(dir, "config"))

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      Application.delete_env(:optimal_system_agent, :auth_req_options)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp with_credentials do
    System.put_env("AWS_ACCESS_KEY_ID", "AKIAEXAMPLEKEY9999")
    System.put_env("AWS_SECRET_ACCESS_KEY", "TOP-SECRET-MATERIAL")
    System.put_env("AWS_REGION", "eu-central-1")
  end

  # Records every request the stub saw, so a test can assert on the HOST the
  # call went to — which is the only way to prove a check hit the free control
  # plane rather than the billed runtime plane.
  defp stub(status, body) do
    {:ok, seen} = Agent.start_link(fn -> [] end)

    plug = fn conn ->
      Agent.update(seen, &[%{host: conn.host, path: conn.request_path, method: conn.method} | &1])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    Application.put_env(:optimal_system_agent, :auth_req_options, plug: plug, retry: false)
    seen
  end

  defp requests(agent), do: Agent.get(agent, &Enum.reverse/1)

  @models %{
    "modelSummaries" => [
      %{
        "modelId" => "anthropic.claude-sonnet-4-5-20250929-v1:0",
        "modelName" => "Claude Sonnet 4.5",
        "providerName" => "Anthropic",
        "inputModalities" => ["TEXT"],
        "outputModalities" => ["TEXT"]
      },
      %{
        "modelId" => "stability.stable-image-core-v1:0",
        "modelName" => "Stable Image Core",
        "providerName" => "Stability AI",
        "inputModalities" => ["TEXT"],
        "outputModalities" => ["IMAGE"]
      }
    ]
  }

  describe "connect/0" do
    test "verifies against the control plane and records a marker" do
      with_credentials()
      seen = stub(200, @models)

      assert {:ok, entry} = Bedrock.connect()
      assert entry["region"] == "eu-central-1"
      assert entry["source"] =~ "environment"
      assert entry["model_count"] == 2
      assert entry["base_url"] == "https://bedrock-runtime.eu-central-1.amazonaws.com"

      assert [%{host: host, path: "/foundation-models", method: "GET"}] = requests(seen)

      # The whole point: `bedrock.` is the control plane and is free.
      # `bedrock-runtime.` is where inference — and billing — happens.
      assert host == "bedrock.eu-central-1.amazonaws.com"
    end

    test "the stored marker contains no AWS secret of any kind" do
      with_credentials()
      System.put_env("AWS_SESSION_TOKEN", "SESSION-TOKEN-MATERIAL")
      stub(200, @models)

      assert {:ok, _} = Bedrock.connect()

      serialized = Jason.encode!(SubscriptionStore.fetch("bedrock"))

      refute serialized =~ "TOP-SECRET-MATERIAL"
      refute serialized =~ "SESSION-TOKEN-MATERIAL"
      refute serialized =~ "AKIAEXAMPLEKEY9999"

      # Only the last four characters of the (non-secret) key id survive, so
      # "which account am I on" stays diagnosable.
      assert SubscriptionStore.fetch("bedrock")["access_key_hint"] == "9999"
      assert SubscriptionStore.fetch("bedrock")["temporary?"] == true
    end

    test "no credentials fails with every source named, and writes nothing" do
      System.put_env("AWS_REGION", "us-east-1")

      assert {:error, {:aws_no_credentials, attempts} = reason} = Bedrock.connect()
      assert length(attempts) == 2
      assert is_nil(SubscriptionStore.fetch("bedrock"))

      message = Bedrock.message(reason)
      assert message =~ "environment"
      assert message =~ "credentials"
      assert message =~ "aws configure"
    end

    test "no region fails before any request is attempted" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIA")
      System.put_env("AWS_SECRET_ACCESS_KEY", "s")
      seen = stub(200, @models)

      assert {:error, {:aws_no_region, _, _} = reason} = Bedrock.connect()
      assert requests(seen) == []
      assert Bedrock.message(reason) =~ "no global endpoint"
    end

    test "a 403 is reported as a permissions problem, not a credential problem" do
      with_credentials()
      stub(403, %{"message" => "not authorized to perform bedrock:ListFoundationModels"})

      assert {:error, {:aws_forbidden, detail} = reason} = Bedrock.connect()
      assert detail =~ "not authorized"

      message = Bedrock.message(reason)
      assert message =~ "signature"
      assert message =~ "IAM"
      # Telling the user to re-authenticate would be wrong: the credential
      # worked. Only the policy is missing.
      refute message =~ "expired"
    end

    test "a 400 points at the clock as well as the credential" do
      with_credentials()
      stub(400, %{"message" => "The security token included in the request is expired"})

      assert {:error, reason} = Bedrock.connect()
      assert Bedrock.message(reason) =~ "clock"
    end

    test "an account with no enabled models is an honest zero, not a failure" do
      with_credentials()
      stub(200, %{})

      assert {:ok, %{"model_count" => 0}} = Bedrock.connect()
    end
  end

  describe "live_status/0" do
    test "refuses to re-create a marker the user removed" do
      with_credentials()
      stub(200, @models)

      assert {:ok, _} = Bedrock.connect()
      assert :ok = Bedrock.logout()

      # This is the sign-out-does-nothing bug. `live_status/0` must not
      # resurrect the marker just because AWS credentials still exist on the
      # machine — they always will.
      assert {:error, :not_connected} = Bedrock.live_status()
      assert is_nil(SubscriptionStore.fetch("bedrock"))
    end

    test "re-checks against AWS when a marker does exist" do
      with_credentials()
      seen = stub(200, @models)

      assert {:ok, _} = Bedrock.connect()
      assert {:ok, _} = Bedrock.live_status()
      assert length(requests(seen)) == 2
    end
  end

  describe "status/0 — pure read" do
    test "is disconnected with no marker, and makes no request" do
      with_credentials()
      seen = stub(200, @models)

      assert %{connected?: false, verified?: false} = Bedrock.status()
      assert requests(seen) == []
    end

    test "reports the region as the plan and the key hint as the account" do
      with_credentials()
      seen = stub(200, @models)
      assert {:ok, _} = Bedrock.connect()

      before = length(requests(seen))
      status = Bedrock.status()

      assert status.connected? and status.verified?
      assert status.plan == "eu-central-1"
      assert status.account == "…9999"
      # An external credential OSA does not hold has no expiry OSA can know.
      assert status.expires_at == nil
      refute status.expired?

      # Drawing a status screen must not dial out.
      assert length(requests(seen)) == before
    end
  end

  describe "credential/0" do
    test "resolves the secret live from the chain, never from the store" do
      with_credentials()
      stub(200, @models)
      assert {:ok, _} = Bedrock.connect()

      System.put_env("AWS_SECRET_ACCESS_KEY", "ROTATED-SECRET")

      assert {:ok, cred} = Bedrock.credential()
      assert cred.credentials.secret_access_key == "ROTATED-SECRET"
      assert cred.region == "eu-central-1"
      assert cred.service == "bedrock"
    end

    test "the region pinned at connect time beats a later ambient AWS_REGION" do
      with_credentials()
      stub(200, @models)
      assert {:ok, _} = Bedrock.connect()

      System.put_env("AWS_REGION", "us-east-1")

      assert {:ok, %{region: "eu-central-1", base_url: url}} = Bedrock.credential()
      assert url == "https://bedrock-runtime.eu-central-1.amazonaws.com"
    end

    test "a revoked credential ends OSA's access, because OSA borrowed rather than copied it" do
      with_credentials()
      stub(200, @models)
      assert {:ok, _} = Bedrock.connect()

      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      assert {:error, {:aws_no_credentials, _}} = Bedrock.credential()
    end
  end

  describe "access_token/0" do
    test "says explicitly that there is no bearer token" do
      # SigV4 is a per-request signature. A caller wanting a token here is
      # about to put an AWS secret in an Authorization header.
      assert {:error, :externally_managed} = Bedrock.access_token()
    end
  end

  describe "logout/0" do
    test "is idempotent and leaves the AWS credentials alone" do
      with_credentials()
      stub(200, @models)
      assert {:ok, _} = Bedrock.connect()

      assert :ok = Bedrock.logout()
      assert :ok = Bedrock.logout()
      assert is_nil(SubscriptionStore.fetch("bedrock"))
      # OSA never held them, so there is nothing here that could remove them.
      assert System.get_env("AWS_SECRET_ACCESS_KEY") == "TOP-SECRET-MATERIAL"
    end
  end

  describe "registration in the subscription surface" do
    test "is dispatchable by provider id" do
      assert Subscription.impl("bedrock") == Bedrock
      assert Subscription.supported?("bedrock")
      assert "bedrock" in Subscription.supported()
    end

    test "is always available — there is no client id to be missing" do
      assert Subscription.available?("bedrock")
    end

    test "routes status through the shared surface" do
      assert %{provider: "bedrock", connected?: false} = Subscription.status("bedrock")
    end
  end
end
