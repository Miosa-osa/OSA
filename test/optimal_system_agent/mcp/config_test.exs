defmodule OptimalSystemAgent.MCP.ConfigTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Config
  alias OptimalSystemAgent.MCP.Config.Server

  test "stdio server (command, no url) is parsed as :stdio" do
    decoded = %{
      "mcpServers" => %{
        "filesystem" => %{
          "command" => "npx",
          "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
          "env" => %{"FOO" => "bar"}
        }
      }
    }

    assert [%Server{} = s] = Config.parse(decoded)
    assert s.name == "filesystem"
    assert s.transport == :stdio
    assert s.command == "npx"
    assert s.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    assert s.env == %{"FOO" => "bar"}
    assert s.enabled
  end

  test "server with url is parsed as :http_sse" do
    decoded = %{"mcpServers" => %{"remote" => %{"url" => "https://example.com/mcp"}}}
    assert [%Server{transport: :http_sse, url: "https://example.com/mcp"}] = Config.parse(decoded)
  end

  test "server names are sanitized to [a-z0-9_]" do
    decoded = %{"mcpServers" => %{"My Server!" => %{"command" => "x"}}}
    assert [%Server{name: "my_server"}] = Config.parse(decoded)
  end

  test "enabled: false is respected" do
    decoded = %{"mcpServers" => %{"a" => %{"command" => "x", "enabled" => false}}}
    assert [%Server{enabled: false}] = Config.parse(decoded)
  end

  test "missing config file yields empty list, not an error" do
    assert {:ok, []} = Config.load("/nonexistent/path/mcp.json")
  end

  test "malformed json yields an error" do
    path = Path.join(System.tmp_dir!(), "mcp_bad_#{System.unique_integer([:positive])}.json")
    File.write!(path, "{not json")
    on_exit(fn -> File.rm(path) end)
    assert {:error, {:invalid_json, _}} = Config.load(path)
  end

  test "load! tolerates a bad file and returns []" do
    path = Path.join(System.tmp_dir!(), "mcp_bad2_#{System.unique_integer([:positive])}.json")
    File.write!(path, "garbage")
    on_exit(fn -> File.rm(path) end)
    assert [] = Config.load!(path)
  end
end
