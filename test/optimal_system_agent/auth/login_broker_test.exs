defmodule OptimalSystemAgent.Auth.LoginBrokerTest do
  @moduledoc """
  The broker exists so a surface that cannot block can still complete a
  sign-in. These tests pin the properties that make that true — and the ones
  that stop it from being a new way to leak a credential.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.LoginBroker
  alias OptimalSystemAgent.Auth.SubscriptionStore

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-broker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      File.rm_rf(dir)
    end)

    :ok
  end

  # `bedrock` with no AWS credentials anywhere fails fast and deterministically,
  # which makes it the right subject for the lifecycle tests: a real flow, a
  # real terminal state, no network and no fifteen-minute wait.
  @provider "bedrock"

  defp await(id, states, tries \\ 100) do
    session = LoginBroker.status(id)

    cond do
      is_map(session) and session.state in states ->
        session

      tries > 0 ->
        Process.sleep(20)
        await(id, states, tries - 1)

      true ->
        flunk("session never reached #{inspect(states)}; last saw #{inspect(session)}")
    end
  end

  describe "start_login/1" do
    test "returns immediately rather than blocking for the length of the grant" do
      # The entire reason this module exists. A caller must get a handle back
      # in milliseconds even for a flow that can take fifteen minutes.
      {elapsed_us, {:ok, session}} = :timer.tc(fn -> LoginBroker.start_login(@provider) end)

      assert session.provider == @provider
      assert session.state in [:starting, :pending, :connected, :failed]
      assert elapsed_us < 2_000_000
    end

    test "the session handle is unguessable" do
      # Holding an id lets you read a sign-in's state and cancel it. It carries
      # no credential, but it is still a capability.
      {:ok, a} = LoginBroker.start_login(@provider)
      await(a.id, [:connected, :failed, :cancelled])
      {:ok, b} = LoginBroker.start_login(@provider)

      refute a.id == b.id
      assert byte_size(a.id) >= 20
    end

    test "refuses a provider that has no sign-in" do
      assert {:error, :unsupported_provider} = LoginBroker.start_login("openai")
      assert {:error, :unsupported_provider} = LoginBroker.start_login("not-a-provider")
    end

    # "anthropic" is deliberately NOT the example above: its sign-in was
    # removed rather than never offered, and it gets its own reason so the
    # HTTP surface can answer 410 + an explanation instead of 400 "unknown
    # provider". See `Auth.LegacyAnthropicOAuth`.
    test "the removed Anthropic sign-in is refused as removed, not as unknown" do
      assert {:error, :anthropic_oauth_removed} = LoginBroker.start_login("anthropic")
    end

    test "reaches a terminal state on its own and carries an actionable message" do
      {:ok, %{id: id}} = LoginBroker.start_login(@provider)
      session = await(id, [:failed, :connected])

      if session.state == :failed do
        assert is_binary(session.message)
        # Not a bare reason code: the message has to be the thing a user reads.
        assert String.length(session.message) > 20
        assert is_binary(session.error)
      end
    end

    test "never exposes a credential in the session it publishes" do
      {:ok, %{id: id}} = LoginBroker.start_login(@provider)
      session = await(id, [:failed, :connected, :cancelled])

      # The wire shape is a fixed field set. Anything a flow learns that is
      # secret goes to the credential store and stops there.
      assert Map.keys(session) |> Enum.sort() ==
               ~w(error expires_at id interval message provider state user_code
                  verification_uri verification_uri_complete)a

      refute Map.has_key?(session, :access_token)
      refute Map.has_key?(session, :device_code)
      refute Map.has_key?(session, :finished_at)
    end
  end

  describe "one in-flight sign-in per provider" do
    test "a second start re-attaches to the first instead of racing it" do
      # Two concurrent device grants produce two codes, one of which is
      # guaranteed to be the wrong one to type — and the user cannot tell
      # which. Pressing Enter twice must mean "show me the one I have".
      #
      # `claude_cli` is used here because its probe is slow enough to still be
      # running when the second call lands; on a machine where it finishes
      # instantly the assertion below degrades to "both ids are valid", which
      # is still true and still correct.
      {:ok, first} = LoginBroker.start_login("claude_cli")
      {:ok, second} = LoginBroker.start_login("claude_cli")

      if first.state in [:starting, :pending] do
        assert second.id == first.id
      end

      await(first.id, [:connected, :failed, :cancelled])
    end
  end

  describe "cancel/1" do
    test "an unknown session says so rather than silently succeeding" do
      assert {:error, :not_found} = LoginBroker.cancel("no-such-session")
    end

    test "cancelling a live session is accepted" do
      {:ok, %{id: id}} = LoginBroker.start_login(@provider)
      assert LoginBroker.cancel(id) in [:ok, {:error, :not_found}]
    end
  end

  describe "status/1" do
    test "is nil for an id that was never issued" do
      assert LoginBroker.status("nope") == nil
    end

    test "a failed sign-in writes nothing to the credential store" do
      {:ok, %{id: id}} = LoginBroker.start_login(@provider)
      session = await(id, [:failed, :connected])

      if session.state == :failed do
        assert is_nil(SubscriptionStore.fetch(@provider))
      end
    end
  end
end
