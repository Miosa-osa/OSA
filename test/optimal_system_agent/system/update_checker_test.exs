defmodule OptimalSystemAgent.System.UpdateCheckerTest do
  @moduledoc """
  Tests for the cached update-availability signal exposed on GET /health.

  Deterministic + offline: the cached result is stubbed via app-env (the same
  seam the /health path reads), so nothing here touches git or the network.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.System.UpdateChecker

  @cache_key :update_status

  setup do
    prev = Application.get_env(:optimal_system_agent, @cache_key)
    prev_enabled = Application.get_env(:optimal_system_agent, :update_check_enabled)

    on_exit(fn ->
      restore(@cache_key, prev)
      restore(:update_check_enabled, prev_enabled)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  describe "health_update/0 (serializer read of the cache)" do
    test "reports available:false with no latest when the checker has no result" do
      Application.delete_env(:optimal_system_agent, @cache_key)

      result = UpdateChecker.health_update()

      assert result.available == false
      assert is_nil(result.latest_version)
      assert is_binary(result.current_version)
    end

    test "reflects a stubbed newer version as available:true with current + latest" do
      Application.put_env(:optimal_system_agent, @cache_key, %{
        available: true,
        current_version: "0.4.6",
        latest_version: "0.5.0"
      })

      result = UpdateChecker.health_update()

      assert result == %{
               available: true,
               current_version: "0.4.6",
               latest_version: "0.5.0"
             }
    end

    test "normalizes a blank/absent latest_version to nil" do
      Application.put_env(:optimal_system_agent, @cache_key, %{
        available: false,
        current_version: "0.4.6",
        latest_version: ""
      })

      assert UpdateChecker.health_update().latest_version == nil
    end

    test "shape is always the three documented keys (JSON-serializable map)" do
      Application.delete_env(:optimal_system_agent, @cache_key)
      result = UpdateChecker.health_update()

      assert Map.keys(result) |> Enum.sort() ==
               [:available, :current_version, :latest_version]

      # Must survive JSON encoding (this is what the /health body does).
      assert {:ok, _json} = Jason.encode(result)
    end
  end

  describe "refresh/0 gating" do
    test "source/dev build pins available:false (no notice)" do
      # The suite runs under Mix, so source_build?/0 is true here — refresh must
      # therefore never flag an update regardless of any local git/changelog.
      assert UpdateChecker.source_build?() == true

      result = UpdateChecker.refresh()

      assert result.available == false
      assert is_nil(result.latest_version)
      # And the cache the /health path reads matches.
      assert UpdateChecker.health_update().available == false
    end

    test "disabled check pins available:false and caches it" do
      Application.put_env(:optimal_system_agent, :update_check_enabled, false)

      result = UpdateChecker.refresh()

      assert result.available == false
      assert Application.get_env(:optimal_system_agent, @cache_key).available == false
    end
  end
end
