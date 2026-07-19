defmodule OptimalSystemAgent.MCP.Transport.HttpTransportTest do
  @moduledoc """
  Transport-fallback selection tests: the pure decision that picks
  StreamableHTTP vs. a fall back to legacy HTTP+SSE, plus legacy endpoint-URL
  resolution.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Transport.Http

  describe "classify_probe/1 (StreamableHTTP → SSE fallback selection)" do
    test "2xx keeps StreamableHTTP" do
      assert Http.classify_probe(200) == :ok
      assert Http.classify_probe(202) == :ok
    end

    test "method-not-allowed / not-found / not-acceptable fall back to SSE" do
      for status <- [404, 405, 406, 415] do
        assert Http.classify_probe(status) == :fallback_sse,
               "expected #{status} to trigger SSE fallback"
      end
    end

    test "other error statuses surface as an error (no silent fallback)" do
      assert Http.classify_probe(401) == {:error, 401}
      assert Http.classify_probe(500) == {:error, 500}
    end
  end

  describe "resolve_endpoint/2 (legacy SSE handshake)" do
    test "absolute URLs are used verbatim" do
      assert Http.resolve_endpoint("https://x.test/sse", "https://y.test/msg") ==
               "https://y.test/msg"
    end

    test "an absolute path is joined onto the stream origin" do
      assert Http.resolve_endpoint("https://x.test/sse", "/messages?session=abc") ==
               "https://x.test/messages?session=abc"
    end

    test "surrounding whitespace is trimmed" do
      assert Http.resolve_endpoint("https://x.test/sse", "  /m  ") == "https://x.test/m"
    end
  end
end
