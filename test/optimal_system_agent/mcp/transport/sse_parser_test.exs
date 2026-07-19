defmodule OptimalSystemAgent.MCP.Transport.SSEParserTest do
  @moduledoc "Framing tests for the pure SSE parser used by the HTTP transport."
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Transport.SSE

  test "splits complete events and keeps a partial remainder" do
    buffer = "event: message\ndata: {\"a\":1}\n\nevent: message\ndata: {\"b\":"
    {events, remainder} = SSE.parse(buffer)

    assert [%{type: "message", data: "{\"a\":1}"}] = events
    assert remainder == "event: message\ndata: {\"b\":"
  end

  test "joins multi-line data with newlines and defaults the event type" do
    assert %{type: "message", data: "line1\nline2"} =
             SSE.parse_event("data: line1\ndata: line2")
  end

  test "captures the endpoint event type and the last-event id" do
    assert %{type: "endpoint", data: "/messages?s=1", id: "42"} =
             SSE.parse_event("event: endpoint\nid: 42\ndata: /messages?s=1")
  end

  test "tolerates CRLF line endings" do
    {events, _} = SSE.parse("event: message\r\ndata: hi\r\n\r\n")
    assert [%{type: "message", data: "hi"}] = events
  end

  test "drops comment-only / heartbeat blocks (no data field)" do
    assert SSE.parse_event(": keep-alive") == nil
    {events, _} = SSE.parse(": ping\n\ndata: real\n\n")
    assert [%{data: "real"}] = events
  end
end
