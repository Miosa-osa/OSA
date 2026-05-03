defmodule OptimalSystemAgent.Channels.HTTP.API.ProviderRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.ProviderRoutes

  @opts ProviderRoutes.init([])

  test "GET / includes structured model metadata per provider" do
    body =
      conn(:get, "/")
      |> ProviderRoutes.call(@opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    providers = body["providers"]
    ollama = Enum.find(providers, &(&1["slug"] == "ollama"))

    assert is_list(ollama["available_models"])
    assert is_list(ollama["models"])
    assert is_integer(ollama["model_count"])

    deepseek = Enum.find(ollama["models"], &(&1["name"] == "deepseek-v4-pro"))
    assert deepseek["context_window"] == 1_000_000
    assert "reasoning" in deepseek["capabilities"]
  end
end
