defmodule OptimalSystemAgent.MCP.PluginManifestTest do
  # async: false — mutates :config_dir / discovery app env, which is global.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Config.Server
  alias OptimalSystemAgent.MCP.Discovery
  alias OptimalSystemAgent.MCP.PluginManifest

  @overridden_env [
    :config_dir,
    :discovery_home_override,
    :mcp_discovery_enabled,
    :mcp_import_foreign,
    :mcp_exclude,
    :mcp_import_only
  ]

  # A fake ~/.osa whose plugins/ dir we fill with bundles.
  defp fake_osa(opts \\ []) do
    home = Path.join(System.tmp_dir!(), "osa-plugin-mcp-#{System.unique_integer([:positive])}")
    osa = Path.join(home, ".osa")
    File.mkdir_p!(Path.join(osa, "plugins"))

    prev = Enum.map(@overridden_env, &{&1, Application.get_env(:optimal_system_agent, &1)})

    Application.put_env(:optimal_system_agent, :config_dir, osa)
    # HOME points at the empty fake tree so no real Codex/Cursor config leaks in.
    Application.put_env(:optimal_system_agent, :discovery_home_override, home)
    Application.put_env(:optimal_system_agent, :mcp_discovery_enabled, true)

    Application.put_env(
      :optimal_system_agent,
      :mcp_import_foreign,
      Keyword.get(opts, :import, true)
    )

    Application.put_env(:optimal_system_agent, :mcp_exclude, Keyword.get(opts, :exclude, []))

    Application.put_env(
      :optimal_system_agent,
      :mcp_import_only,
      Keyword.get(opts, :import_only, [])
    )

    on_exit(fn ->
      Enum.each(prev, fn
        {key, nil} -> Application.delete_env(:optimal_system_agent, key)
        {key, value} -> Application.put_env(:optimal_system_agent, key, value)
      end)

      File.rm_rf(home)
    end)

    %{home: home, osa: osa, plugins: Path.join(osa, "plugins")}
  end

  defp bundle(ctx, name, files) do
    dir = Path.join(ctx.plugins, name)
    File.mkdir_p!(dir)

    Enum.each(files, fn {file, content} ->
      body = if is_binary(content), do: content, else: Jason.encode!(content)
      File.write!(Path.join(dir, file), body)
    end)

    dir
  end

  defp mcp_json(servers) do
    %{
      "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
      "mcpServers" => servers
    }
  end

  describe "streamable-http entries" do
    test "a streamable-http server becomes a first-class http_sse server" do
      ctx = fake_osa()

      bundle(ctx, "deployer", %{
        "plugin.json" => %{"name" => "deployer"},
        "mcp.json" =>
          mcp_json(%{
            "deploy" => %{
              "type" => "streamable-http",
              "url" => "https://deploy.example.test/mcp",
              "headers" => %{"X-Tenant" => "acme"}
            }
          })
      })

      assert [%Server{} = server] = PluginManifest.servers()
      assert server.name == "deployer_deploy"
      assert server.transport == :http_sse
      assert server.url == "https://deploy.example.test/mcp"
      assert server.headers == %{"x-tenant" => "acme"}
      assert server.source == :plugin
    end

    test "\"http\" and \"sse\" types are accepted — OSA implements both paths" do
      ctx = fake_osa()

      bundle(ctx, "mixed", %{
        "mcp.json" =>
          mcp_json(%{
            "a" => %{"type" => "http", "url" => "https://a.example.test/mcp"},
            "b" => %{"type" => "sse", "url" => "https://b.example.test/sse"}
          })
      })

      names = PluginManifest.servers() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["mixed_a", "mixed_b"]
      assert Enum.all?(PluginManifest.servers(), &(&1.transport == :http_sse))
    end

    test "an entry with a url but no type is remote, matching MCP.Config's rule" do
      ctx = fake_osa()
      bundle(ctx, "bare", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      assert [%Server{transport: :http_sse, name: "bare_x"}] = PluginManifest.servers()
    end

    test "cleartext http to a non-loopback host is refused" do
      ctx = fake_osa()

      bundle(ctx, "leaky", %{
        "mcp.json" =>
          mcp_json(%{
            "remote" => %{
              "type" => "streamable-http",
              "url" => "http://remote.example.test/mcp",
              "headers" => %{"Authorization" => "Bearer secret"}
            }
          })
      })

      assert [] = PluginManifest.servers()
    end

    test "cleartext http to loopback is allowed — that is a local dev server" do
      ctx = fake_osa()

      bundle(ctx, "local", %{
        "mcp.json" =>
          mcp_json(%{
            "dev" => %{"type" => "streamable-http", "url" => "http://127.0.0.1:8000/mcp"}
          })
      })

      assert [%Server{name: "local_dev"}] = PluginManifest.servers()
    end

    test "a url embedding credentials is refused" do
      ctx = fake_osa()

      bundle(ctx, "creds", %{
        "mcp.json" =>
          mcp_json(%{"x" => %{"type" => "http", "url" => "https://u:p@x.example.test/mcp"}})
      })

      assert [] = PluginManifest.servers()
    end

    test "a header value smuggling a newline is refused" do
      ctx = fake_osa()

      bundle(ctx, "inject", %{
        "mcp.json" =>
          mcp_json(%{
            "x" => %{
              "type" => "http",
              "url" => "https://x.example.test/mcp",
              "headers" => %{"X-A" => "ok\r\nX-Evil: yes"}
            }
          })
      })

      assert [] = PluginManifest.servers()
    end
  end

  describe "stdio entries and placeholders" do
    test "${PLUGIN_ROOT} expands to the bundle directory" do
      ctx = fake_osa()

      dir =
        bundle(ctx, "worker", %{
          "mcp.json" =>
            mcp_json(%{
              "run" => %{
                "type" => "stdio",
                "command" => "python",
                "args" => ["${PLUGIN_ROOT}/server.py"],
                "env" => %{"CACHE" => "${PLUGIN_DATA}/cache"}
              }
            })
        })

      assert [%Server{} = server] = PluginManifest.servers()
      assert server.transport == :stdio
      assert server.command == "python"
      assert server.args == [Path.join(dir, "server.py")]
      assert server.env["CACHE"] == Path.join(PluginManifest.data_dir("worker"), "cache")
      # The placeholders are also exported so the child process can resolve them.
      assert server.env["PLUGIN_ROOT"] == dir
    end

    test "an unknown ${VAR} is left literal, never read from OSA's environment" do
      ctx = fake_osa()

      bundle(ctx, "envleak", %{
        "mcp.json" =>
          mcp_json(%{
            "run" => %{"type" => "stdio", "command" => "python", "args" => ["${HOME}", "${PATH}"]}
          })
      })

      assert [%Server{args: ["${HOME}", "${PATH}"]}] = PluginManifest.servers()
    end

    test "a path escaping the plugin root is refused" do
      ctx = fake_osa()

      bundle(ctx, "escape", %{
        "mcp.json" =>
          mcp_json(%{
            "run" => %{
              "type" => "stdio",
              "command" => "sh",
              "args" => ["${PLUGIN_ROOT}/../../../etc/passwd"]
            }
          })
      })

      assert [] = PluginManifest.servers()
    end

    test "a ./-relative command is refused because no working directory can be set" do
      ctx = fake_osa()

      bundle(ctx, "rel", %{
        "mcp.json" => mcp_json(%{"run" => %{"type" => "stdio", "command" => "./server"}})
      })

      assert [] = PluginManifest.servers()
    end

    test "a ${PLUGIN_ROOT}-rooted command is accepted and made absolute" do
      ctx = fake_osa()

      dir =
        bundle(ctx, "rooted", %{
          "mcp.json" =>
            mcp_json(%{"run" => %{"type" => "stdio", "command" => "${PLUGIN_ROOT}/bin/server"}})
        })

      assert [%Server{command: command}] = PluginManifest.servers()
      assert command == Path.join(dir, "bin/server")
    end

    test "reading a manifest never creates the PLUGIN_DATA directory" do
      ctx = fake_osa()

      bundle(ctx, "nodata", %{
        "mcp.json" =>
          mcp_json(%{
            "run" => %{"type" => "stdio", "command" => "x", "env" => %{"D" => "${PLUGIN_DATA}"}}
          })
      })

      assert [_] = PluginManifest.servers()
      refute File.exists?(PluginManifest.data_dir("nodata"))
    end
  end

  describe "manifest shapes and isolation" do
    test "plugin.json may declare mcpServers inline" do
      ctx = fake_osa()

      bundle(ctx, "inline", %{
        "plugin.json" => %{
          "name" => "inline",
          "mcpServers" => %{"x" => %{"type" => "http", "url" => "https://x.example.test/mcp"}}
        }
      })

      assert [%Server{name: "inline_x"}] = PluginManifest.servers()
    end

    test "mcp.json wins over plugin.json for the same server name" do
      ctx = fake_osa()

      bundle(ctx, "both", %{
        "plugin.json" => %{
          "name" => "both",
          "mcpServers" => %{"x" => %{"type" => "http", "url" => "https://old.example.test/mcp"}}
        },
        "mcp.json" =>
          mcp_json(%{"x" => %{"type" => "http", "url" => "https://new.example.test/mcp"}})
      })

      assert [%Server{url: "https://new.example.test/mcp"}] = PluginManifest.servers()
    end

    test "the declared name beats the directory name" do
      ctx = fake_osa()

      bundle(ctx, "dir-name", %{
        "plugin.json" => %{"name" => "Declared Name"},
        "mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.example.test/mcp"}})
      })

      assert [%Server{name: "declared_name_x"}] = PluginManifest.servers()
    end

    test "two bundles declaring the same server name do not collide" do
      ctx = fake_osa()
      spec = mcp_json(%{"worker" => %{"url" => "https://w.example.test/mcp"}})
      bundle(ctx, "alpha", %{"mcp.json" => spec})
      bundle(ctx, "beta", %{"mcp.json" => spec})

      names = PluginManifest.servers() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["alpha_worker", "beta_worker"]
    end

    test "a qualified name carries no __ , which would break tool-key parsing" do
      ctx = fake_osa()

      bundle(ctx, "a__b", %{"mcp.json" => mcp_json(%{"c__d" => %{"url" => "https://x.test/mcp"}})})

      assert [%Server{name: name}] = PluginManifest.servers()
      refute String.contains?(name, "__")

      assert {:ok, {^name, "tool"}} =
               OptimalSystemAgent.MCP.Client.ToolBridge.parse_key("mcp__#{name}__tool")
    end

    test "one malformed entry does not take its siblings down" do
      ctx = fake_osa()

      bundle(ctx, "mixed", %{
        "mcp.json" =>
          mcp_json(%{
            "good" => %{"type" => "http", "url" => "https://good.example.test/mcp"},
            "bad_type" => %{"type" => "carrier-pigeon"},
            "no_url" => %{"type" => "streamable-http"},
            "not_a_map" => "nope"
          })
      })

      assert [%Server{name: "mixed_good"}] = PluginManifest.servers()
    end

    test "a malformed bundle does not take the scan down" do
      ctx = fake_osa()
      bundle(ctx, "broken", %{"mcp.json" => "{ not json"})
      bundle(ctx, "fine", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      assert [%Server{name: "fine_x"}] = PluginManifest.servers()
    end

    test "a missing plugins directory is not an error" do
      assert PluginManifest.servers("/nonexistent/osa/plugins") == []
    end

    test "a stray file in the plugins directory (a .exs plugin) is ignored" do
      ctx = fake_osa()
      File.write!(Path.join(ctx.plugins, "legacy.exs"), "defmodule X do end")
      assert PluginManifest.servers() == []
    end
  end

  describe "discovery integration — offered, never auto-run" do
    test "plugin servers appear in the discovery menu tagged with their source" do
      ctx = fake_osa(import: false)
      bundle(ctx, "acme", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      assert [%Server{name: "acme_x", source: :plugin}] = Discovery.available()
    end

    test "nothing is imported until the operator opts in" do
      ctx = fake_osa(import: false)
      bundle(ctx, "acme", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      assert Discovery.discover() == []
    end

    test "opting in imports the plugin server" do
      ctx = fake_osa(import: true)
      bundle(ctx, "acme", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      assert [%Server{name: "acme_x", source: :plugin}] = Discovery.discover()
    end

    test "the deny list beats the allow list" do
      ctx = fake_osa(import: true, import_only: ["acme_x"], exclude: ["acme_x"])
      bundle(ctx, "acme", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      assert Discovery.discover() == []
      refute Discovery.importable?("acme_x")
    end

    test "the allow list restricts the import path but not the menu" do
      ctx = fake_osa(import: true, import_only: ["acme_x"])
      bundle(ctx, "acme", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})
      bundle(ctx, "other", %{"mcp.json" => mcp_json(%{"y" => %{"url" => "https://y.test/mcp"}})})

      assert [%Server{name: "acme_x"}] = Discovery.discover()

      menu = Discovery.available() |> Enum.map(& &1.name) |> Enum.sort()
      assert menu == ["acme_x", "other_y"]
    end

    test "an excluded plugin server is absent from the menu too" do
      ctx = fake_osa(import: true, exclude: ["acme_x"])
      bundle(ctx, "acme", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      assert Discovery.available() == []
    end

    test "a native server of the same name wins" do
      ctx = fake_osa(import: true)
      bundle(ctx, "acme", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      File.write!(
        Path.join(ctx.osa, "mcp.json"),
        Jason.encode!(%{"mcpServers" => %{"acme_x" => %{"command" => "native"}}})
      )

      assert Discovery.discover() == []
    end

    test "the kill switch suppresses plugin manifests along with everything else" do
      ctx = fake_osa(import: true)
      bundle(ctx, "acme", %{"mcp.json" => mcp_json(%{"x" => %{"url" => "https://x.test/mcp"}})})

      Application.put_env(:optimal_system_agent, :mcp_discovery_enabled, false)

      assert Discovery.available() == []
      assert Discovery.discover() == []
    end

    test ":plugin is a known source with a label and a path" do
      ctx = fake_osa()
      assert :plugin in Discovery.all_sources()
      assert Discovery.source_label(:plugin) =~ "plugin"
      assert Discovery.source_path(:plugin) == ctx.plugins
    end
  end
end
