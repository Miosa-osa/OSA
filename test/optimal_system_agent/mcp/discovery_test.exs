defmodule OptimalSystemAgent.MCP.DiscoveryTest do
  # async: false — mutates app env (:discovery_home_override, :config_dir) which
  # is process-global. Each test uses its own tmp HOME and restores env on exit.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Config.Server
  alias OptimalSystemAgent.MCP.Discovery

  # Every app-env key fake_home/1 overrides, saved + restored per test.
  @overridden_env [
    :discovery_home_override,
    :config_dir,
    :mcp_discovery_enabled,
    :mcp_import_foreign,
    :mcp_exclude
  ]

  # Build a fresh fake HOME under tmp, point discovery + native config at it,
  # and restore the prior app env when the test finishes.
  #
  # `import: true` (the default here) additionally OPTS IN to foreign-config
  # import, because that is off by default now — see the "opt-in" describe block
  # below, which uses `import: false` to prove the default.
  defp fake_home(opts \\ []) do
    home = Path.join(System.tmp_dir!(), "osa-discovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    prev = Enum.map(@overridden_env, &{&1, Application.get_env(:optimal_system_agent, &1)})

    Application.put_env(:optimal_system_agent, :discovery_home_override, home)
    # Native OSA config also lives under the fake home so we can test that a
    # native server name beats a discovered one.
    Application.put_env(:optimal_system_agent, :config_dir, Path.join(home, ".osa"))
    # The suite-wide kill switch is off in config/test.exs; lift it for this
    # test only, now that HOME points somewhere harmless.
    Application.put_env(:optimal_system_agent, :mcp_discovery_enabled, true)

    Application.put_env(
      :optimal_system_agent,
      :mcp_import_foreign,
      Keyword.get(opts, :import, true)
    )

    Application.put_env(:optimal_system_agent, :mcp_exclude, Keyword.get(opts, :exclude, []))

    on_exit(fn ->
      File.rm_rf(home)
      OptimalSystemAgent.Settings.reset_cache()
      Enum.each(prev, fn {key, value} -> restore(key, value) end)
    end)

    OptimalSystemAgent.Settings.reset_cache()
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
    Jason.encode!(%{
      "mcpServers" => %{"desktop_one" => %{"url" => "https://desktop.example/mcp"}}
    })
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

  # ── Foreign import is OPT-IN ────────────────────────────────────────────
  #
  # The bug this covers: OSA read ~/.claude.json, ~/.claude/mcp.json, the Claude
  # Desktop config and ~/.cursor/mcp.json at boot and RAN every server it found.
  # A user who never configured a server for OSA ended up with 18 servers and
  # hundreds of tool definitions they did not choose and could not attribute.
  describe "foreign-config import is off by default" do
    test "populated foreign configs import NOTHING when not opted in" do
      home = fake_home(import: false)
      write(home, [".codex", "config.toml"], codex_toml())
      write(home, [".claude", "mcp.json"], claude_mcp_json())
      write(home, [".cursor", "mcp.json"], cursor_mcp_json())
      write(home, [".config", "Claude", "claude_desktop_config.json"], desktop_json())

      refute Discovery.import_enabled?()
      assert Discovery.discover() == []
    end

    test "the same configs DO import once opted in via app env" do
      home = fake_home(import: true)
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      assert Discovery.import_enabled?()
      assert "claude_only" in Enum.map(Discovery.discover(), & &1.name)
    end

    test "the settings cascade (~/.osa/settings.json) can opt in" do
      home = fake_home(import: false)
      write(home, [".claude", "mcp.json"], claude_mcp_json())
      write(home, [".osa", "settings.json"], Jason.encode!(%{"mcp_import_foreign" => true}))
      OptimalSystemAgent.Settings.reset_cache()

      assert Discovery.import_enabled?()
      assert "claude_only" in Enum.map(Discovery.discover(), & &1.name)
    end

    test "settings false beats an app-env true (explicit user decision wins)" do
      home = fake_home(import: true)
      write(home, [".claude", "mcp.json"], claude_mcp_json())
      write(home, [".osa", "settings.json"], Jason.encode!(%{"mcp_import_foreign" => false}))
      OptimalSystemAgent.Settings.reset_cache()

      refute Discovery.import_enabled?()
      assert Discovery.discover() == []
    end

    test "available/0 reports what COULD be imported without importing it" do
      home = fake_home(import: false)
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      # Nothing is imported...
      assert Discovery.discover() == []
      # ...but the operator can still be shown what exists, with attribution.
      available = Discovery.available()
      assert "claude_only" in Enum.map(available, & &1.name)
      assert Enum.all?(available, &(&1.source == :claude_code))
    end

    test "source_label/1 attributes every source in human terms" do
      assert Discovery.source_label(:osa) == "osa config"
      assert Discovery.source_label(:claude_code) =~ "claude code"
      assert Discovery.source_label(:claude_desktop) =~ "claude desktop"
      assert Discovery.source_label(:cursor) =~ "cursor"
      assert Discovery.source_label(:codex) =~ "codex"
    end

    test "mcp_import_sources narrows which foreign tools are read" do
      home = fake_home(import: true)
      write(home, [".codex", "config.toml"], codex_toml())
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      prev = Application.get_env(:optimal_system_agent, :mcp_import_sources)
      Application.put_env(:optimal_system_agent, :mcp_import_sources, [:codex])
      on_exit(fn -> restore(:mcp_import_sources, prev) end)

      names = Enum.map(Discovery.discover(), & &1.name)
      assert "codex_stdio" in names
      refute "claude_only" in names
    end
  end

  # ── Per-server deny list ────────────────────────────────────────────────
  describe "mcp_exclude deny list" do
    alias OptimalSystemAgent.MCP.Config

    test "an excluded name is dropped from an imported foreign config" do
      home = fake_home(import: true, exclude: ["claude_only"])
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      names = Enum.map(Discovery.discover(), & &1.name)
      refute "claude_only" in names
      # Only the one named server is killed — the rest of the source survives.
      assert "shared" in names
    end

    test "exclusion matches before/after name sanitization" do
      home = fake_home(import: true, exclude: ["Claude-Only"])
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      assert Config.excluded?("claude_only")
      refute "claude_only" in Enum.map(Discovery.discover(), & &1.name)
    end

    test "an excluded OSA-OWN server never reaches startup" do
      home = fake_home(import: false, exclude: ["collide"])
      write(home, [".osa", "mcp.json"], native_json())

      # Still visible as raw config...
      assert Enum.any?(Config.load_all(), &(&1.name == "collide"))
      # ...but never started.
      refute Enum.any?(Config.load_startup(), &(&1.name == "collide"))
    end

    test "the deny list is also readable from ~/.osa/settings.json" do
      home = fake_home(import: true, exclude: [])
      write(home, [".claude", "mcp.json"], claude_mcp_json())
      write(home, [".osa", "settings.json"], Jason.encode!(%{"mcp_exclude" => ["claude_only"]}))
      OptimalSystemAgent.Settings.reset_cache()

      assert Config.excluded?("claude_only")
      refute "claude_only" in Enum.map(Discovery.discover(), & &1.name)
    end

    test "an empty deny list excludes nothing" do
      home = fake_home(import: true, exclude: [])
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      refute Config.excluded?("claude_only")
      assert "claude_only" in Enum.map(Discovery.discover(), & &1.name)
    end
  end

  # ── OSA's own configs are untouched by all of the above ─────────────────
  describe "OSA's own config still loads exactly as before" do
    alias OptimalSystemAgent.MCP.Config

    test "~/.osa/mcp.json loads and starts with foreign import off" do
      home = fake_home(import: false)
      write(home, [".osa", "mcp.json"], native_json())
      # A populated foreign config that must be ignored entirely.
      write(home, [".claude", "mcp.json"], claude_mcp_json())

      startup = Config.load_startup()

      assert [%Server{name: "collide", source: :osa, scope: :user, command: "native-collide"}] =
               startup
    end

    test "the workspace .mcp.json still loads (project scope, approval-gated)" do
      home = fake_home(import: false)
      project = Path.join(home, "workspace")
      File.mkdir_p!(project)

      File.write!(
        Path.join(project, ".mcp.json"),
        Jason.encode!(%{"mcpServers" => %{"proj_one" => %{"command" => "proj-cmd"}}})
      )

      OptimalSystemAgent.Workspace.Cwd.put_process_override(project)
      on_exit(fn -> OptimalSystemAgent.Workspace.Cwd.clear_process_override() end)

      assert %Server{name: "proj_one", scope: :project, source: :osa} =
               Enum.find(Config.load_all(), &(&1.name == "proj_one"))
    end
  end
end
