defmodule OptimalSystemAgent.System.UpdaterTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.System.Updater

  describe "module" do
    test "defines expected struct fields" do
      state = %Updater{}
      assert Map.has_key?(state, :update_url)
      assert Map.has_key?(state, :check_interval)
      assert Map.has_key?(state, :available_update)
      assert Map.has_key?(state, :enabled)
      assert state.enabled == false
      assert state.check_interval == 86_400_000
    end
  end

  # Note: Full integration tests require a running GenServer and mock HTTP server.
  # These unit tests verify the struct and basic behavior.
  describe "version comparison" do
    test "struct defaults are sensible" do
      state = %Updater{}
      assert is_nil(state.update_url)
      assert is_nil(state.available_update)
      assert is_nil(state.last_check)
    end
  end
end
