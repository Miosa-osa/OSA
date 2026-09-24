defmodule OptimalSystemAgent.Agent.LoopSignalQualityTest do
  @moduledoc """
  Dedicated coverage for `Agent.Loop.maybe_enforce_signal_quality/2` — the
  display-side half of Signal Theory applied to OSA's OWN output
  (`:signal_quality_enforcement_enabled`, ON by default in
  `config/config.exs`, OFF in `config/test.exs`).

  Calls the function directly (it is `@doc false`-public for exactly this,
  same convention as `Loop.compact_and_refresh_tokens/1` and
  `Loop.reset_per_turn_fields/1`), so no LLM mock / full turn is needed to
  prove the flag actually gates behavior and that the trim it performs is
  safe.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop

  setup do
    original = Application.get_env(:optimal_system_agent, :signal_quality_enforcement_enabled)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:optimal_system_agent, :signal_quality_enforcement_enabled)
      else
        Application.put_env(:optimal_system_agent, :signal_quality_enforcement_enabled, original)
      end
    end)

    :ok
  end

  describe "off (config/test.exs default)" do
    test "passes the response through completely unchanged, even filler-laden text" do
      Application.put_env(:optimal_system_agent, :signal_quality_enforcement_enabled, false)

      response = "Let me think about this. Let me think about this. Done."
      assert Loop.maybe_enforce_signal_quality(response, %{}) == response
    end
  end

  describe "on (the config/config.exs production default)" do
    setup do
      Application.put_env(:optimal_system_agent, :signal_quality_enforcement_enabled, true)
      :ok
    end

    test "trims a pure-filler sentence out of the response" do
      response = "Let me think about this. The build is fixed."
      result = Loop.maybe_enforce_signal_quality(response, %{})

      refute result =~ "Let me think about this"
      assert result =~ "The build is fixed"
    end

    test "high-S/N output (code, a path, a number) passes through completely unchanged" do
      response = "The fix is in `lib/foo.ex` line 42. Run `mix test` to confirm."
      assert Loop.maybe_enforce_signal_quality(response, %{}) == response
    end

    test "never removes a duplicated sentence containing a command" do
      response = "Run `git status` first. Run `git status` first."
      result = Loop.maybe_enforce_signal_quality(response, %{})

      assert (result |> String.split("Run `git status` first.") |> length()) - 1 == 2
    end

    test "never removes a duplicated sentence containing a path" do
      response = "Check /var/log/app.log now. Check /var/log/app.log now."
      result = Loop.maybe_enforce_signal_quality(response, %{})

      assert (result |> String.split("/var/log/app.log") |> length()) - 1 == 2
    end

    test "never removes a duplicated sentence containing a number" do
      response = "Step 3 restarts the service. Step 3 restarts the service."
      result = Loop.maybe_enforce_signal_quality(response, %{})

      assert (result |> String.split("Step 3 restarts the service.") |> length()) - 1 == 2
    end

    test "a non-binary response passes through unchanged rather than raising" do
      assert Loop.maybe_enforce_signal_quality(nil, %{}) == nil
    end
  end
end
