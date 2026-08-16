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

  # `refresh/0` stamps every cache entry it writes; a hand-built stub has to do
  # the same or it is (correctly) read as an answer of unknown age.
  defp fresh_cache(map), do: Map.put(map, :checked_at, System.system_time(:millisecond))

  describe "health_update/0 (serializer read of the cache)" do
    test "reports available:false with no latest when the checker has no result" do
      Application.delete_env(:optimal_system_agent, @cache_key)

      result = UpdateChecker.health_update()

      assert result.available == false
      assert is_nil(result.latest_version)
      assert is_binary(result.current_version)
    end

    test "reflects a stubbed newer version as available:true with current + latest" do
      Application.put_env(
        :optimal_system_agent,
        @cache_key,
        fresh_cache(%{
          available: true,
          current_version: "0.4.6",
          latest_version: "0.5.0"
        })
      )

      result = UpdateChecker.health_update()

      assert result == %{
               available: true,
               current_version: "0.4.6",
               latest_version: "0.5.0"
             }
    end

    test "normalizes a blank/absent latest_version to nil" do
      Application.put_env(
        :optimal_system_agent,
        @cache_key,
        fresh_cache(%{
          available: false,
          current_version: "0.4.6",
          latest_version: ""
        })
      )

      assert UpdateChecker.health_update().latest_version == nil
    end

    test "a confirmed up-to-date install is distinguishable from an unchecked one" do
      # The whole point of the field. `available: false` alone cannot tell a
      # caller whether we asked and got "no" or never managed to ask, and an
      # updater that reports the reassuring one for both is how a user with a
      # published release waiting was told they were current.
      Application.put_env(
        :optimal_system_agent,
        @cache_key,
        fresh_cache(%{
          available: false,
          current_version: "1.0.100",
          latest_version: "1.0.100"
        })
      )

      confirmed = UpdateChecker.health_update()
      assert confirmed.available == false
      assert confirmed.latest_version == "1.0.100"

      Application.delete_env(:optimal_system_agent, @cache_key)

      unchecked = UpdateChecker.health_update()
      assert unchecked.available == false
      assert unchecked.latest_version == nil
    end

    test "a stale cached answer stops being reported as fact" do
      # Bounded on purpose: the refresh timer is daily, so a checker that died,
      # a machine that suspended, or a network that went away would otherwise
      # keep serving an arbitrarily old "up to date" as though it had just been
      # established.
      Application.put_env(:optimal_system_agent, @cache_key, %{
        available: false,
        current_version: "1.0.99",
        latest_version: "1.0.99",
        checked_at: System.system_time(:millisecond) - 30 * 86_400_000
      })

      result = UpdateChecker.health_update()

      assert result.available == false
      assert result.latest_version == nil, "a month-old answer must read as 'could not check'"
    end

    test "an unstamped legacy cache is treated as unprovable, not as fresh" do
      Application.put_env(:optimal_system_agent, @cache_key, %{
        available: false,
        current_version: "1.0.99",
        latest_version: "1.0.99"
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
