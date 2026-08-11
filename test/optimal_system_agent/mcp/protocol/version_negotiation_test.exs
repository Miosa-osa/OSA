defmodule OptimalSystemAgent.MCP.Protocol.VersionNegotiationTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Protocol.Messages
  alias OptimalSystemAgent.MCP.Server.Dispatcher

  describe "announced revision" do
    test "announces 2025-06-18, the revision matching the transport OSA implements" do
      assert Messages.protocol_version() == "2025-06-18"
    end

    test "2025-03-26 is supported for negotiation but is NOT what OSA announces" do
      # 2025-03-26 made JSON-RPC batching mandatory for receivers and OSA frames
      # one message at a time; 2025-06-18 removed batching again.
      assert Messages.supports_version?("2025-03-26")
      refute Messages.protocol_version() == "2025-03-26"
    end

    test "the legacy revision stays supported because the SSE fallback still targets it" do
      assert Messages.supports_version?("2024-11-05")
    end

    test "an unknown revision is not supported" do
      refute Messages.supports_version?("2099-01-01")
      refute Messages.supports_version?(nil)
      refute Messages.supports_version?(:latest)
    end
  end

  describe "initialize announces only implemented capabilities" do
    test "declares roots, which ServerSession answers" do
      caps = Messages.initialize()["params"]["capabilities"]
      assert caps["roots"] == %{"listChanged" => false}
    end

    test "does not declare elicitation — OSA has no way to answer elicitation/create" do
      caps = Messages.initialize()["params"]["capabilities"]
      refute Map.has_key?(caps, "elicitation")
    end

    test "does not declare sampling — OSA answers no sampling/createMessage" do
      caps = Messages.initialize()["params"]["capabilities"]
      refute Map.has_key?(caps, "sampling")
    end

    test "does not declare tools, which is a server capability and never a client one" do
      caps = Messages.initialize()["params"]["capabilities"]
      refute Map.has_key?(caps, "tools")
    end

    test "the announced version is the one carried in the handshake" do
      assert Messages.initialize()["params"]["protocolVersion"] == Messages.protocol_version()
    end
  end

  describe "negotiate_version/1 — OSA as client" do
    test "accepts the revision it asked for" do
      assert {:ok, "2025-06-18"} =
               Messages.negotiate_version(%{"protocolVersion" => "2025-06-18"})
    end

    test "accepts a server that negotiates DOWN to a supported revision" do
      assert {:ok, "2024-11-05"} =
               Messages.negotiate_version(%{"protocolVersion" => "2024-11-05"})

      assert {:ok, "2025-03-26"} =
               Messages.negotiate_version(%{"protocolVersion" => "2025-03-26"})
    end

    test "refuses a revision OSA cannot speak rather than continuing blind" do
      assert {:error, {:unsupported_protocol_version, "2030-01-01"}} =
               Messages.negotiate_version(%{"protocolVersion" => "2030-01-01"})
    end

    test "refuses a non-string protocolVersion" do
      assert {:error, {:unsupported_protocol_version, 20_250_618}} =
               Messages.negotiate_version(%{"protocolVersion" => 20_250_618})
    end

    test "a result omitting protocolVersion keeps the announced revision" do
      assert {:ok, version} = Messages.negotiate_version(%{"capabilities" => %{}})
      assert version == Messages.protocol_version()
    end
  end

  describe "negotiate_server_version/1 — OSA as server" do
    test "echoes the client's revision when supported" do
      assert Messages.negotiate_server_version("2024-11-05") == "2024-11-05"
      assert Messages.negotiate_server_version("2025-03-26") == "2025-03-26"
    end

    test "answers with its own latest when the client asks for something unsupported" do
      assert Messages.negotiate_server_version("2030-01-01") == Messages.protocol_version()
      assert Messages.negotiate_server_version(nil) == Messages.protocol_version()
    end

    test "the dispatcher's initialize reply follows the negotiation" do
      {:reply, response} =
        Dispatcher.dispatch({:request, 1, "initialize", %{"protocolVersion" => "2024-11-05"}})

      assert response["result"]["protocolVersion"] == "2024-11-05"

      {:reply, response} =
        Dispatcher.dispatch({:request, 2, "initialize", %{"protocolVersion" => "1999-01-01"}})

      assert response["result"]["protocolVersion"] == Messages.protocol_version()
    end

    test "the dispatcher announces only the tools capability it actually serves" do
      {:reply, response} = Dispatcher.dispatch({:request, 3, "initialize", %{}})
      caps = response["result"]["capabilities"]

      assert caps["tools"] == %{"listChanged" => false}
      refute Map.has_key?(caps, "resources")
      refute Map.has_key?(caps, "prompts")
      refute Map.has_key?(caps, "completions")
    end
  end

  describe "validate_protocol_version_header/1 — OSA as HTTP server" do
    test "a missing header assumes 2025-03-26, per the transport spec" do
      assert {:ok, "2025-03-26"} = Messages.validate_protocol_version_header(nil)
      assert {:ok, "2025-03-26"} = Messages.validate_protocol_version_header("")
      assert {:ok, "2025-03-26"} = Messages.validate_protocol_version_header("   ")
    end

    test "a supported header value is accepted verbatim" do
      assert {:ok, "2025-06-18"} = Messages.validate_protocol_version_header("2025-06-18")
      assert {:ok, "2024-11-05"} = Messages.validate_protocol_version_header(" 2024-11-05 ")
    end

    test "an unsupported value is an error the HTTP layer must turn into a 400" do
      assert {:error, {:unsupported_protocol_version, "2030-01-01"}} =
               Messages.validate_protocol_version_header("2030-01-01")

      assert {:error, {:unsupported_protocol_version, "garbage"}} =
               Messages.validate_protocol_version_header("garbage")

      assert {:error, {:unsupported_protocol_version, 5}} =
               Messages.validate_protocol_version_header(5)
    end
  end

  describe "content blocks added by the revisions OSA now claims" do
    test "structuredContent survives when the server sends no text mirror" do
      result = %{
        "content" => [],
        "structuredContent" => %{"temperature" => 22, "unit" => "C"}
      }

      assert {:ok, text} = Messages.normalize_tool_result(result)
      assert {:ok, decoded} = Jason.decode(text)
      assert decoded == %{"temperature" => 22, "unit" => "C"}
    end

    test "a text mirror still wins over structuredContent" do
      result = %{
        "content" => [%{"type" => "text", "text" => "22C"}],
        "structuredContent" => %{"temperature" => 22}
      }

      assert {:ok, "22C"} = Messages.normalize_tool_result(result)
    end

    test "a resource_link keeps its uri instead of collapsing to a block count" do
      result = %{
        "content" => [
          %{"type" => "resource_link", "uri" => "file:///tmp/report.md", "name" => "report"}
        ]
      }

      assert {:ok, text} = Messages.normalize_tool_result(result)
      assert text =~ "file:///tmp/report.md"
      assert text =~ "report"
    end

    test "a resource_link without a name still keeps the uri" do
      result = %{"content" => [%{"type" => "resource_link", "uri" => "https://x.test/a"}]}
      assert {:ok, "[resource_link: https://x.test/a]"} = Messages.normalize_tool_result(result)
    end

    test "an audio block is named rather than silently dropped" do
      result = %{"content" => [%{"type" => "audio", "data" => "AAA", "mimeType" => "audio/wav"}]}

      assert {:ok, text} = Messages.normalize_tool_result(result)
      assert text == "[audio: audio/wav]"
    end

    test "an error result still reports as an error with its text" do
      result = %{"isError" => true, "content" => [%{"type" => "text", "text" => "boom"}]}
      assert {:error, "boom"} = Messages.normalize_tool_result(result)
    end

    test "a genuinely empty result stays empty" do
      assert {:ok, ""} = Messages.normalize_tool_result(%{"content" => []})
    end
  end
end
