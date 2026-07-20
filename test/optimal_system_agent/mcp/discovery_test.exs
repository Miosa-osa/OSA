defmodule OptimalSystemAgent.MCP.DiscoveryTest do
  # async: false — mutates app env (:discovery_home_override, :config_dir) which
  # is process-global. Each test uses its own tmp HOME and restores env on exit.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Config.Server
  alias OptimalSystemAgent.MCP.Discovery

  # Build a fresh fake HOME under tmp, point discovery + native config at it,
  # and restore the prior app env when the test finishes.
  defp fake_home(_context \\ %{}) do
    home = Path.join(System.tmp_dir!(), "osa-discovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    prev_home = Application.get_env(:optimal_system_agent, :discovery_home_override)
    prev_cfg = Application.get_env(:optimal_system_agent, :config_dir)

    Application.put_env(:optimal_system_agent, :discovery_home_override, home)
    # Native OSA config also lives under the fake home so we can test that a
    # native server name beats a discovered one.
    Application.put_env(:optimal_system_agent, :config_dir, Path.join(home, ".osa"))

    on_exit(fn ->
      File.rm_rf(home)
      restore(:discovery_home_override, prev_home)
      restore(:config_dir, prev_cfg)
    end)

    home
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp write(home, rel_path, contents) do
    path = Path.join([home | rel_path])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp codex_toml do
    """
    [mcp_servers.codex_stdio]
    command = "npx"
    args = ["-y", "codex-server"]
    env = { TOKEN = "abc" }

    [mcp_servers.codex_http]
    url = "https://codex.example.com/mcp"

    [mcp_servers.shared]
    command = "shared-codex"

    [mcp_servers.collide]
    command = "codex-collide"
    """
  end

  defp claude_mcp_json do
    Jason.encode!(%{
      "mcpServers" => %{
        "shared" => %{"command" => "shared-claude"},
        "claude_only" => %{"command" => "claude-cmd", "args" => ["run"]}
      }
    })
  end

  defp cursor_mcp_json do
    Jason.encode!(%{"mcpServers" => %{"cursor_one" => %{"command" => "cursor-cmd"}}})
  end

  defp desktop_json do
    Jason.encode!(%{"mcpServers" => %{"desktop_one" => %{"url" => "https://desktop.example/mcp"}}})
  end

  defp native_json do
    Jason.encode!(%{"mcpServers" => %{"collide" => %{"command" => "native-collide"}}})
  end

  defp by_name(servers), do: Map.new(servers, fn s -> {s.name, s} end)

  describe "discover/0" do
    test "reads all external sources, parses stdio + url, tags each source" do
      home = fake_home()
      write(home, [".codex", "config.toml"], codex_toml())
      write(home, [".claude", "mcp.json"], claude_mcp_json())
      write(home, [".cursor", "mcp.json"], cursor_mcp_json())
      write(home, [".config", "Claude", "claude_desktop_config.json"], desktop_json())
      write(home, [".osa", "mcp.json"], native_json())

      servers = Discovery.discover()
      map = by_name(servers)

      # Codex stdio server: command/args/env parsed.
      assert %Server{} = codex = map["codex_stdio"]
      assert codex.transport == :stdio
      assert codex.command == "npx"
      assert codex.args == ["-y", "codex-server"]
      assert codex.env == %{"TOKEN" => "abc"}
      assert codex.source == :codex
      # Discovered servers auto-connect on boot (enabled: true). This is safe
      # because ServerSession caps consecutive connect failures and goes dormant,
      # so a borrowed config that 404s can no longer storm the daemon.
      assert codex.enabled

      # Codex http server: url parsed as :http_sse.
      assert %Server{transport: :http_sse, url: "https://codex.example.com/mcp", source: :codex} =
               map["codex_http"]

      # Claude Code only server.
      assert %Server{source: :claude_code, command: "claude-cmd"} = map["claude_only"]

      # Cursor server.
      assert %Server{source: :cursor} = map["cursor_one"]

      # Claude Desktop server (url form).
      assert %Server{source: :claude_desktop, transport: :http_sse} = map["desktop_one"]
    end

    test "a name in both Codex and Claude appears once with :codex (precedence)" do
      home = fake_home()
      write(home, [".codex", "config.toml"], codex_toml())
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      servers = Discovery.discover()
      shared = Enum.filter(servers, &(&1.name == "shared"))

      assert [%Server{source: :codex, command: "shared-codex"}] = shared
    end

    test "a name also present natively is excluded (native wins)" do
      home = fake_home()
      write(home, [".codex", "config.toml"], codex_toml())
      write(home, [".osa", "mcp.json"], native_json())

      servers = Discovery.discover()

      # "collide" is in codex AND native -> discovery drops it so native wins.
      refute Enum.any?(servers, &(&1.name == "collide"))

      # It is still available via the native path with source :osa.
      native = OptimalSystemAgent.MCP.Config.load_all()
      assert %Server{name: "collide", source: :osa, command: "native-collide"} =
               Enum.find(native, &(&1.name == "collide"))
    end

    test "missing files yield [] and never crash" do
      _home = fake_home()
      assert Discovery.discover() == []
    end

    test "malformed TOML and malformed JSON are skipped, no crash" do
      home = fake_home()
      write(home, [".codex", "config.toml"], "this is = not [ valid toml")
      write(home, [".cursor", "mcp.json"], "{not json at all")
      # A valid source alongside the broken ones still comes through.
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      servers = Discovery.discover()
      names = Enum.map(servers, & &1.name)

      # Broken codex/cursor contributed nothing; valid claude survived.
      assert "claude_only" in names
      refute "cursor_one" in names
      refute "codex_stdio" in names
    end
  end
end
