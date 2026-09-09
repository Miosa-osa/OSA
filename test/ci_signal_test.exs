defmodule OptimalSystemAgent.Test.CiSignalTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Test.CiSignal

  describe "pinned_toolchain?/1" do
    # Takes the environment as an explicit map rather than reading the real
    # `System.get_env/0`, so this is testable without mutating global OS env
    # state (this module is `async: true`).
    test "true only when both ELIXIR_VERSION and OTP_VERSION are present and non-empty" do
      assert CiSignal.pinned_toolchain?(%{
               "ELIXIR_VERSION" => "1.17.3",
               "OTP_VERSION" => "26.2.5"
             })

      refute CiSignal.pinned_toolchain?(%{"ELIXIR_VERSION" => "1.17.3"})
      refute CiSignal.pinned_toolchain?(%{"OTP_VERSION" => "26.2.5"})
      refute CiSignal.pinned_toolchain?(%{})
      refute CiSignal.pinned_toolchain?(%{"ELIXIR_VERSION" => "", "OTP_VERSION" => "26.2.5"})
    end

    test "defaults to the real environment when called with no argument" do
      # Whatever this shell happens to be, the default arg must agree with
      # passing System.get_env() explicitly — proves the default is wired up,
      # without asserting a particular true/false (that depends on whether
      # THIS test run is local or CI).
      assert CiSignal.pinned_toolchain?() == CiSignal.pinned_toolchain?(System.get_env())
    end
  end
end
