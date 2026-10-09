defmodule OptimalSystemAgent.Onboarding.ProvisionedTest do
  @moduledoc """
  Onboarding runs only for a genuinely unconfigured local user. Configured by
  environment, by MIOSA's platform env file, by `~/.osa/.env`, or told to skip
  (`OSA_SKIP_ONBOARDING`, `--no-onboarding`): no wizard, no picker, in the TUI
  too. The launchers carry the same rule in shell; a test keeps them equal.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Onboarding
  alias OptimalSystemAgent.Onboarding.Provisioned

  @moduletag :tmp_dir

  @scrubbed Provisioned.provider_keys() ++
              ~w(OSA_SKIP_ONBOARDING OSA_PLATFORM_ENV_FILE MIOSA_AI_GATEWAY_KEY OSA_HOME)

  defp with_env(overrides, fun) do
    snapshot = System.get_env()
    Enum.each(@scrubbed, &System.delete_env/1)
    System.put_env("OSA_PLATFORM_ENV_FILE", "/nonexistent/osa-provisioned-test/env.sh")
    Enum.each(overrides, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      System.get_env()
      |> Map.keys()
      |> Enum.each(fn k -> unless Map.has_key?(snapshot, k), do: System.delete_env(k) end)

      Enum.each(snapshot, fn {k, v} -> System.put_env(k, v) end)
    end
  end

  describe "env_configured?/1" do
    test "every provider key counts, blank does not" do
      refute Provisioned.env_configured?(%{})

      for key <- Provisioned.provider_keys() do
        assert Provisioned.env_configured?(%{key => "value"}), key
        refute Provisioned.env_configured?(%{key => "  "}), "#{key} blank"
      end
    end

    test "the keys the owner named are all in the list" do
      for key <- ~w(OLLAMA_API_KEY OPENAI_API_KEY OPENAI_BASE_URL MIOSA_AI_GATEWAY_URL
                    ANTHROPIC_API_KEY ANTHROPIC_BASE_URL OSA_DEFAULT_PROVIDER OSA_MODEL) do
        assert key in Provisioned.provider_keys()
      end
    end

    test "OSA_SKIP_ONBOARDING" do
      for yes <- ["1", "true", "YES", " on "] do
        assert Provisioned.env_configured?(%{"OSA_SKIP_ONBOARDING" => yes})
      end

      for no <- ["0", "false", "", "later"] do
        refute Provisioned.env_configured?(%{"OSA_SKIP_ONBOARDING" => no})
      end
    end
  end

  describe "files" do
    test "envd's /opt/osagent/env.sh shape", %{tmp_dir: dir} do
      path = Path.join(dir, "env.sh")

      File.write!(path, """
      #!/bin/bash
      # Platform-provided credentials (injected via envd configure)
      export OPTIMAL_API_URL="https://api.miosa.ai"
      export OSA_HOME="/home/ubuntu/.osa"
      # MIOSA AI Gateway: OSA's OpenAI-compatible provider, no vendor key.
      export OSA_DEFAULT_PROVIDER=openai
      export MIOSA_AI_GATEWAY_URL='https://api.miosa.ai/api/v1/intelligence'
      export OPENAI_API_KEY='it'\\''s-a-key'
      """)

      assert Provisioned.file_configured?(path)
      env = Provisioned.parse_env(File.read!(path))
      assert env["OPENAI_API_KEY"] == "it's-a-key"
      assert env["MIOSA_AI_GATEWAY_URL"] == "https://api.miosa.ai/api/v1/intelligence"
    end

    test "an env.sh without a provider (gateway not configured) does not count", %{tmp_dir: dir} do
      path = Path.join(dir, "env.sh")
      File.write!(path, ~s(export OPTIMAL_API_URL="x"\nexport MIOSA_TENANT_ID="t"\n))
      refute Provisioned.file_configured?(path)
      refute Provisioned.file_configured?(Path.join(dir, "missing.sh"))
    end
  end

  describe "Onboarding.first_run?/0" do
    test "unconfigured local user: onboarding runs", %{tmp_dir: home} do
      with_env(%{"OSA_HOME" => home}, fn -> assert Onboarding.first_run?() end)
    end

    test "a provider key in the environment skips it", %{tmp_dir: home} do
      with_env(%{"OSA_HOME" => home, "OLLAMA_API_KEY" => "k"}, fn ->
        refute Onboarding.first_run?()
      end)
    end

    test "OSA_SKIP_ONBOARDING skips it", %{tmp_dir: home} do
      with_env(%{"OSA_HOME" => home, "OSA_SKIP_ONBOARDING" => "1"}, fn ->
        refute Onboarding.first_run?()
      end)
    end

    test "the platform env file skips it", %{tmp_dir: home} do
      file = Path.join(home, "platform-env.sh")
      File.write!(file, "export OSA_DEFAULT_PROVIDER=openai\n")

      with_env(%{"OSA_HOME" => home}, fn ->
        System.put_env("OSA_PLATFORM_ENV_FILE", file)
        refute Onboarding.first_run?()
      end)
    end

    test "a key in ~/.osa/.env without a provider line skips it", %{tmp_dir: home} do
      File.write!(Path.join(home, ".env"), "OPENAI_API_KEY=sk-test\n")
      with_env(%{"OSA_HOME" => home}, fn -> refute Onboarding.first_run?() end)
    end
  end

  describe "the launcher rule (bin/osa)" do
    @launcher Path.expand("../../bin/osa", __DIR__)

    test "the shell key list is the Elixir key list" do
      [_, keys] = Regex.run(~r/^OSA_PROVIDER_ENV_KEYS="([^"]+)"/m, File.read!(@launcher))
      assert String.split(keys) == Provisioned.provider_keys()
    end

    test "onboarding_provisioned agrees with Provisioned on every case", %{tmp_dir: dir} do
      source = File.read!(@launcher)
      [keys_line] = Regex.run(~r/^OSA_PROVIDER_ENV_KEYS=.*$/m, source)
      [function] = Regex.run(~r/^onboarding_provisioned\(\) \{\n.*?^\}$/ms, source)

      env_file = Path.join(dir, "platform.sh")
      File.write!(env_file, "export ANTHROPIC_API_KEY='k'\n")
      dotenv_home = Path.join(dir, "home")
      File.mkdir_p!(dotenv_home)
      File.write!(Path.join(dotenv_home, ".env"), "OSA_SKIP_ONBOARDING=true\n")

      cases = [
        {%{}, false},
        {%{"OPENAI_BASE_URL" => "http://gw"}, true},
        {%{"OSA_SKIP_ONBOARDING" => "yes"}, true},
        {%{"OSA_SKIP_ONBOARDING" => "0"}, false},
        {%{"OSA_PLATFORM_ENV_FILE" => env_file}, true},
        {%{"OSA_HOME" => dotenv_home}, true}
      ]

      for {env, expected} <- cases do
        script = """
        #{keys_line}
        #{function}
        if onboarding_provisioned; then echo yes; else echo no; fi
        """

        base = %{
          "PATH" => System.get_env("PATH"),
          "OSA_PLATFORM_ENV_FILE" => "",
          "OSA_HOME" => Path.join(dir, "empty-home")
        }

        {out, 0} =
          System.cmd("bash", ["-c", script],
            env: Map.to_list(Map.merge(base, env)) ++ clear_env()
          )

        assert String.trim(out) == if(expected, do: "yes", else: "no"), inspect(env)
      end
    end
  end

  # `System.cmd/3` inherits the suite's environment; unset every provider key
  # the developer or CI may have exported.
  defp clear_env do
    for key <- Provisioned.provider_keys() ++ ["OSA_SKIP_ONBOARDING"],
        System.get_env(key) != nil,
        do: {key, nil}
  end
end
