defmodule OptimalSystemAgent.ConfigFileTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants

  setup do
    prev_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_boot = Application.get_env(:optimal_system_agent, :bootstrap_dir)

    tmp = Path.join(System.tmp_dir!(), "osa_cfg_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)
    # bootstrap_dir must not shadow config_dir in these tests
    Application.delete_env(:optimal_system_agent, :bootstrap_dir)
    ConfigFile.reload()

    on_exit(fn ->
      restore(:config_dir, prev_dir)
      restore(:bootstrap_dir, prev_boot)
      ConfigFile.reload()
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, v), do: Application.put_env(:optimal_system_agent, key, v)

  defp write_toml(tmp, body) do
    File.write!(Path.join(tmp, "config.toml"), body)
    ConfigFile.reload()
  end

  defp write_json(tmp, body) do
    File.write!(Path.join(tmp, "config.json"), body)
    ConfigFile.reload()
  end

  describe "defaults" do
    test "load/0 returns built-in defaults when no files exist" do
      cfg = ConfigFile.load()
      assert cfg["tui"]["theme"] == "dark"
      assert cfg["tui"]["verbosity"] == "normal"
      assert cfg["permissions"]["ask_commands"] == []
      assert ConfigFile.shell_timeout_ms() == nil
      assert ConfigFile.provider() == nil
      assert ConfigFile.mcp_servers() == %{}
    end
  end

  describe "user overrides win" do
    test "toml values override defaults", %{tmp: tmp} do
      write_toml(tmp, """
      [model]
      provider = "openai"
      model = "gpt-x"
      effort = "high"

      [model.params]
      temperature = 0.7

      [shell]
      timeout_ms = 45000

      [tui]
      theme = "light"
      verbosity = "verbose"
      """)

      assert ConfigFile.provider() == "openai"
      assert ConfigFile.model_name() == "gpt-x"
      assert ConfigFile.effort() == "high"
      assert ConfigFile.model_params()["temperature"] == 0.7
      assert ConfigFile.shell_timeout_ms() == 45_000
      assert ConfigFile.tui_theme() == "light"
      assert ConfigFile.tui_verbosity() == "verbose"
    end

    test "deep merge keeps untouched default keys", %{tmp: tmp} do
      write_toml(tmp, """
      [tui]
      theme = "light"
      """)

      # theme overridden, verbosity falls through to default
      assert ConfigFile.tui_theme() == "light"
      assert ConfigFile.tui_verbosity() == "normal"
    end

    test "mcp_servers pass through", %{tmp: tmp} do
      write_toml(tmp, """
      [mcp_servers.linear]
      url = "https://mcp.linear.app/mcp"

      [mcp_servers.local]
      command = "bun"
      args = ["run", "bin.ts"]
      enabled = false
      """)

      servers = ConfigFile.mcp_servers()
      assert servers["linear"]["url"] == "https://mcp.linear.app/mcp"
      assert servers["local"]["command"] == "bun"
      assert servers["local"]["args"] == ["run", "bin.ts"]
      assert servers["local"]["enabled"] == false
    end
  end

  describe "back-compat with config.json" do
    test "json provides model/provider when no toml", %{tmp: tmp} do
      write_json(tmp, ~s({"model":"legacy-model","provider":"ollama"}))
      assert ConfigFile.provider() == "ollama"
      assert ConfigFile.model_name() == "legacy-model"
    end

    test "toml overrides config.json (toml wins)", %{tmp: tmp} do
      write_json(tmp, ~s({"model":"legacy-model","provider":"ollama"}))

      write_toml(tmp, """
      [model]
      provider = "openai"
      """)

      # provider comes from toml, model still from json (deep-merge)
      assert ConfigFile.provider() == "openai"
      assert ConfigFile.model_name() == "legacy-model"
    end
  end

  describe "boot resolution routing (config.toml [model])" do
    alias OptimalSystemAgent.Application, as: App

    test "toml_model_section reads config.toml ONLY (no config.json overlay)", %{tmp: tmp} do
      write_json(tmp, ~s({"model":"legacy-model","provider":"ollama"}))
      # no config.toml yet → toml-only section is empty even though json has provider
      assert ConfigFile.toml_model_section() == %{}

      write_toml(tmp, """
      [model]
      provider = "openai"
      """)

      section = ConfigFile.toml_model_section()
      assert section["provider"] == "openai"
      # config.json's model must NOT leak into the toml-only section
      refute Map.has_key?(section, "model")
    end

    test "config.toml [model].provider/model override config.json", %{tmp: tmp} do
      write_json(tmp, ~s({"model":"json-model","provider":"ollama"}))

      write_toml(tmp, """
      [model]
      provider = "openai"
      model = "gpt-x"
      """)

      # provider resolves from config.toml, beating both env and json
      assert App.resolve_provider(ConfigFile.toml_model_section(), "anthropic", :ollama) ==
               :openai

      # model resolves from config.toml (ConfigFile.model_name/0 is the chain top)
      assert ConfigFile.model_name() == "gpt-x"
    end

    test "absent/empty [model] preserves config.json + env/default resolution", %{tmp: tmp} do
      write_json(tmp, ~s({"model":"json-model","provider":"ollama"}))
      # no config.toml written

      # model falls back to the config.json selection, exactly as before
      assert ConfigFile.model_name() == "json-model"

      toml_model = ConfigFile.toml_model_section()
      # env override still wins when config.toml sets no provider
      assert App.resolve_provider(toml_model, "anthropic", :ollama) == :anthropic
      # and with neither toml nor env, the app default is used
      assert App.resolve_provider(toml_model, nil, :ollama) == :ollama
    end

    test "effort override resolves; invalid/absent effort is ignored", %{tmp: tmp} do
      write_toml(tmp, """
      [model]
      effort = "high"
      """)

      assert ConfigFile.effort() == "high"
      assert App.resolve_effort(ConfigFile.effort()) == :high

      assert App.resolve_effort("bogus") == nil
      assert App.resolve_effort(nil) == nil
    end
  end

  describe "permission lists merge with Constants defaults" do
    test "ask_commands extend the built-in defaults", %{tmp: tmp} do
      write_toml(tmp, """
      [permissions]
      ask_commands = ["deploy", "terraform"]
      """)

      eff = Constants.effective_ask_commands()
      # built-in defaults preserved
      assert "rm" in eff
      assert "sudo" in eff
      # operator extensions merged in
      assert "deploy" in eff
      assert "terraform" in eff
      # raw defaults accessor unchanged
      refute "deploy" in Constants.ask_commands()
    end

    test "catastrophic_patterns and deny extend hard-deny tier", %{tmp: tmp} do
      write_toml(tmp, ~S"""
      [permissions]
      catastrophic_patterns = ['\bterraform\s+destroy\b']
      deny = ["shutdown"]
      """)

      cat = Constants.effective_catastrophic_patterns()
      assert Enum.any?(cat, &Regex.match?(&1, "terraform destroy -auto-approve"))
      assert "shutdown" in Constants.deny_commands()
    end

    test "allow list downgrades a risky command", %{tmp: tmp} do
      write_toml(tmp, """
      [permissions]
      allow = ["chmod"]
      """)

      assert "chmod" in Constants.allow_commands()
    end

    test "shell timeout override flows through Constants.effective_timeout_ms", %{tmp: tmp} do
      assert Constants.effective_timeout_ms() == Constants.default_timeout_ms()

      write_toml(tmp, """
      [shell]
      timeout_ms = 30000
      """)

      assert Constants.effective_timeout_ms() == 30_000
    end
  end

  describe "generic getter + malformed input" do
    test "get/2 with path and default", %{tmp: tmp} do
      write_toml(tmp, """
      [tui]
      theme = "light"
      """)

      assert ConfigFile.get(["tui", "theme"], "dark") == "light"
      assert ConfigFile.get(["nope", "missing"], :fallback) == :fallback
    end

    test "malformed toml falls back to defaults without crashing", %{tmp: tmp} do
      File.write!(Path.join(tmp, "config.toml"), "this is = = not valid toml [[[")
      ConfigFile.reload()

      # defaults still resolve; permission gate still returns built-ins
      assert ConfigFile.tui_theme() == "dark"
      assert "rm" in Constants.effective_ask_commands()
    end
  end

  describe "default template" do
    test "write_default_template writes when absent and never clobbers", %{tmp: tmp} do
      assert {:ok, path} = ConfigFile.write_default_template()
      assert File.exists?(path)
      contents = File.read!(path)
      assert contents =~ "[model]"
      assert contents =~ "[permissions]"

      # second call must NOT overwrite
      assert {:ok, :exists} = ConfigFile.write_default_template()
      assert File.read!(path) == contents
      _ = tmp
    end
  end
end
