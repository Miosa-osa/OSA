defmodule OptimalSystemAgent.Channels.HTTP.API.ModelsListTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.DataRoutes

  @opts DataRoutes.init([])

  setup do
    provider = Application.get_env(:optimal_system_agent, :default_provider)
    model = Application.get_env(:optimal_system_agent, :default_model)

    on_exit(fn ->
      restore_env(:default_provider, provider)
      restore_env(:default_model, model)
    end)

    Application.put_env(:optimal_system_agent, :default_provider, :ollama)
    Application.put_env(:optimal_system_agent, :default_model, "kimi-k2.6:cloud")

    :ok
  end

  test "GET / includes curated provider and Ollama Cloud models" do
    body =
      conn(:get, "/")
      |> DataRoutes.call(@opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    models = body["models"]
    names = Enum.map(models, & &1["name"])

    assert "kimi-k2.6:cloud" in names
    assert "deepseek-v4-pro" in names
    assert "gemini-3-flash-preview" in names
    assert "mistral-large-3:675b-cloud" in names
    assert "gpt-5.5" in names
    assert "claude-opus-4-7" in names

    deepseek = Enum.find(models, &(&1["name"] == "deepseek-v4-pro"))
    assert deepseek["context_window"] == 1_000_000

    kimi = Enum.find(models, &(&1["name"] == "kimi-k2.6:cloud"))
    assert kimi["provider"] == "ollama"
    assert kimi["context_window"] == 256_000
    assert is_boolean(kimi["configured"])
    assert "cloud" in kimi["capabilities"]
    assert kimi["active"] == true
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, value), do: Application.put_env(:optimal_system_agent, key, value)
end
