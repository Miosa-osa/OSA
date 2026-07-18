defmodule OptimalSystemAgent.MCP.OutputLimiterTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.OutputLimiter

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_mcp_out_#{System.unique_integer([:positive])}")
    prev_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_max = Application.get_env(:optimal_system_agent, :max_mcp_output_tokens)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)
    Application.put_env(:optimal_system_agent, :max_mcp_output_tokens, 5)

    on_exit(fn ->
      restore(:config_dir, prev_dir)
      restore(:max_mcp_output_tokens, prev_max)
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  test "small text passes through unchanged" do
    assert {:ok, "hi"} = OutputLimiter.limit({:ok, "hi"}, "srv", "tool")
  end

  test "oversize text spills to a file with read instructions" do
    big = String.duplicate("x", 200)
    assert {:ok, out} = OutputLimiter.limit({:ok, big}, "srv", "tool")
    assert out =~ "exceeds maximum allowed tokens"
    assert out =~ "tool-results"
  end

  test "non-text results pass through" do
    assert {:error, "boom"} = OutputLimiter.limit({:error, "boom"}, "srv", "tool")
    image = {:ok, {:image, %{}}}
    assert ^image = OutputLimiter.limit(image, "srv", "tool")
  end
end
