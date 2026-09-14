defmodule OptimalSystemAgent.Test.EnvIsolationTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Test.EnvIsolation

  @env_key "OSA_ENV_ISOLATION_TEST_KEY"
  @app_key :env_isolation_test_key

  describe "snapshot/1 and restore/1" do
    test "restores an OS env key that was set" do
      System.put_env(@env_key, "before")
      snap = EnvIsolation.snapshot(env: [@env_key])

      System.put_env(@env_key, "mutated")
      assert System.get_env(@env_key) == "mutated"

      assert EnvIsolation.restore(snap) == :ok
      assert System.get_env(@env_key) == "before"
    after
      System.delete_env(@env_key)
    end

    test "restores an OS env key that was unset back to unset (not left mutated)" do
      System.delete_env(@env_key)
      snap = EnvIsolation.snapshot(env: [@env_key])

      System.put_env(@env_key, "leaked-by-test")
      assert System.get_env(@env_key) == "leaked-by-test"

      EnvIsolation.restore(snap)
      assert System.get_env(@env_key) == nil
    after
      System.delete_env(@env_key)
    end

    test "restores an Application env key that was set" do
      Application.put_env(:optimal_system_agent, @app_key, :original)
      snap = EnvIsolation.snapshot(app_env: [@app_key])

      Application.put_env(:optimal_system_agent, @app_key, :mutated)
      assert Application.get_env(:optimal_system_agent, @app_key) == :mutated

      EnvIsolation.restore(snap)
      assert Application.get_env(:optimal_system_agent, @app_key) == :original
    after
      Application.delete_env(:optimal_system_agent, @app_key)
    end

    test "restores an Application env key that was unset back to unset" do
      Application.delete_env(:optimal_system_agent, @app_key)
      snap = EnvIsolation.snapshot(app_env: [@app_key])

      Application.put_env(:optimal_system_agent, @app_key, :leaked)
      EnvIsolation.restore(snap)

      assert Application.get_env(:optimal_system_agent, @app_key) == nil
    after
      Application.delete_env(:optimal_system_agent, @app_key)
    end

    test "supports a non-default app for app_env keys" do
      Application.put_env(:kernel, @app_key, :kernel_original)
      snap = EnvIsolation.snapshot(app: :kernel, app_env: [@app_key])

      Application.put_env(:kernel, @app_key, :mutated)
      EnvIsolation.restore(snap)

      assert Application.get_env(:kernel, @app_key) == :kernel_original
    after
      Application.delete_env(:kernel, @app_key)
    end
  end

  describe "protect/1" do
    test "the on_exit restore it registers fires after later on_exit hooks and lands on the original value" do
      System.put_env(@env_key, "before-protect")

      # Registered BEFORE `protect/1` — `on_exit` runs LIFO, so this fires
      # LAST, i.e. AFTER protect's own restore-on_exit. An assertion failure
      # inside `on_exit` is attributed to this test by ExUnit, so this proves
      # both the ordering promise in `protect/1`'s moduledoc AND that the
      # restore actually lands on the pre-mutation value, not just that it
      # runs at some point.
      on_exit(fn ->
        assert System.get_env(@env_key) == "before-protect"
        System.delete_env(@env_key)
      end)

      assert EnvIsolation.protect(env: [@env_key]) == :ok
      System.put_env(@env_key, "mutated-in-test")
      assert System.get_env(@env_key) == "mutated-in-test"
    end
  end

  # A real consumer of `use EnvIsolation` — ExUnit auto-discovers this as its
  # OWN test case (any `use ExUnit.Case` module in a required `.exs` file
  # runs as a normal, independent test), so it doubles as an integration
  # smoke test: the generated `setup` must actually run without error and
  # not interfere with the test body.
  defmodule ConsumerTest do
    use ExUnit.Case, async: false
    use OptimalSystemAgent.Test.EnvIsolation, env: ["OSA_ENV_ISOLATION_CONSUMER_KEY"]

    test "a module that uses EnvIsolation can freely mutate its protected keys" do
      System.put_env("OSA_ENV_ISOLATION_CONSUMER_KEY", "set-inside-consumer-test")
      assert System.get_env("OSA_ENV_ISOLATION_CONSUMER_KEY") == "set-inside-consumer-test"
    end
  end
end
