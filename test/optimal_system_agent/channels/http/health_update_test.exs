defmodule OptimalSystemAgent.Channels.HTTP.HealthUpdateTest do
  @moduledoc """
  GET /health carries the cached `update` object (available/current/latest).

  Offline + deterministic: the cached signal is stubbed via app-env; the route
  never fetches. Exercises the real router so the serializer wiring is covered.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias OptimalSystemAgent.Channels.HTTP

  @opts HTTP.init([])
  @cache_key :update_status

  setup do
    prev = Application.get_env(:optimal_system_agent, @cache_key)
    on_exit(fn -> restore(@cache_key, prev) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp get_health do
    conn = conn(:get, "/health") |> HTTP.call(@opts)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  test "includes an update object with available:false when no update is cached" do
    Application.delete_env(:optimal_system_agent, @cache_key)

    body = get_health()

    assert %{"update" => update} = body
    assert update["available"] == false
    assert Map.has_key?(update, "current_version")
    assert Map.get(update, "latest_version") == nil
  end

  test "surfaces a stubbed newer version as available:true with current + latest" do
    Application.put_env(:optimal_system_agent, @cache_key, %{
      available: true,
      current_version: "0.4.6",
      latest_version: "0.5.0"
    })

    body = get_health()

    assert body["update"] == %{
             "available" => true,
             "current_version" => "0.4.6",
             "latest_version" => "0.5.0"
           }
  end
end
