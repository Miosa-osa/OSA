defmodule OptimalSystemAgent.MCP.Transport.StdioHardeningTest do
  @moduledoc """
  Regression test for the inbound-buffer cap in the stdio MCP transport
  (finding 8). An MCP server that streams a very large result, or dies/hangs
  mid-frame without a trailing newline, previously grew state.buffer without
  bound and could OOM the node. handle_info now drops an oversized unframed
  remainder instead of accumulating it.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Transport.Stdio

  @cap 16 * 1024 * 1024

  test "oversized unframed data (no newline) resets the buffer instead of growing" do
    state = %Stdio{port: :fake_port, buffer: "", name: "test"}

    # A chunk larger than the cap with NO newline — cannot be framed.
    huge = :binary.copy("a", @cap + 10)

    {:noreply, new_state} = Stdio.handle_info({:fake_port, {:data, huge}}, state)

    assert new_state.buffer == ""
  end

  test "normal newline-delimited frames still buffer their partial remainder" do
    # owner/ref set so the complete line delivers to this process harmlessly.
    state = %Stdio{port: :fake_port, owner: self(), ref: make_ref(), buffer: "", name: "test"}

    # A complete line plus a small partial remainder — remainder is kept.
    data = ~s({"jsonrpc":"2.0"}\n{"partial":)

    {:noreply, new_state} = Stdio.handle_info({:fake_port, {:data, data}}, state)

    assert new_state.buffer == ~s({"partial":)
  end
end
