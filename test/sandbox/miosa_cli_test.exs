defmodule OptimalSystemAgent.Sandbox.MiosaCliTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Sandbox.MiosaCli
  alias OptimalSystemAgent.Sandbox.Router

  @keys [:miosa_cli_path, :miosa_cli_config, :sandbox_miosa_cli, :sandbox_backend]

  setup do
    previous = Enum.map(@keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})
    original_env = System.get_env("MIOSA_PLATFORM_API_KEY")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:optimal_system_agent, key, value)
        {key, :error} -> Application.delete_env(:optimal_system_agent, key)
      end)

      if original_env,
        do: System.put_env("MIOSA_PLATFORM_API_KEY", original_env),
        else: System.delete_env("MIOSA_PLATFORM_API_KEY")
    end)

    System.delete_env("MIOSA_PLATFORM_API_KEY")
    :ok
  end

  defp write_cli_config(contents) do
    path = Path.join(System.tmp_dir!(), "miosa-config-#{System.unique_integer([:positive])}.json")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:optimal_system_agent, :miosa_cli_config, path)
    path
  end

  defp fake_cli do
    path = Path.join(System.tmp_dir!(), "fake-miosa-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:optimal_system_agent, :miosa_cli_path, path)
    path
  end

  describe "availability" do
    test "is false when the configured CLI path does not exist" do
      Application.put_env(:optimal_system_agent, :miosa_cli_path, "/nonexistent/miosa")
      write_cli_config(~s({"api_key": "msk_test"}))

      refute MiosaCli.available?()
    end

    test "resolves the credential from the CLI config, not just the env var" do
      fake_cli()
      write_cli_config(~s({"api_key": "msk_test", "tenant": "acme"}))

      # This is the regression that made the HTTP backend dead on arrival: an
      # operator who ran `miosa login` has no MIOSA_PLATFORM_API_KEY set.
      refute System.get_env("MIOSA_PLATFORM_API_KEY")
      assert MiosaCli.available?()
    end

    test "is false when the CLI config carries no api_key" do
      fake_cli()
      write_cli_config(~s({"tenant": "acme"}))

      refute MiosaCli.available?()
    end

    test "is false when the CLI config is absent or unreadable" do
      fake_cli()
      Application.put_env(:optimal_system_agent, :miosa_cli_config, "/nonexistent/config.json")

      refute MiosaCli.available?()
    end

    test "an explicit env var still wins for headless installs" do
      fake_cli()
      Application.put_env(:optimal_system_agent, :miosa_cli_config, "/nonexistent/config.json")
      System.put_env("MIOSA_PLATFORM_API_KEY", "msk_env")

      assert MiosaCli.available?()
    end
  end

  describe "exec result decoding" do
    test "surfaces a non-zero exit code instead of reporting success" do
      body = %{"stdout" => "out\n", "stderr" => "boom\n", "exit_code" => 42}

      assert {:ok, text} =
               MiosaCli.format_result(MiosaCli.collect_output(body), MiosaCli.exit_code(body))

      assert text =~ "out"
      assert text =~ "boom"
      assert text =~ "[exit code: 42]"
    end

    test "a successful command carries no exit-code annotation" do
      body = %{"stdout" => "fine\n", "stderr" => "", "exit_code" => 0}

      assert {:ok, "fine\n"} =
               MiosaCli.format_result(MiosaCli.collect_output(body), MiosaCli.exit_code(body))
    end

    test "stdout and stderr are kept separable rather than jammed together" do
      body = %{"stdout" => "a", "stderr" => "b", "exit_code" => 0}
      assert MiosaCli.collect_output(body) == "a\nb"
    end

    test "a string exit code is still understood" do
      assert MiosaCli.exit_code(%{"exit_code" => "7"}) == 7
    end

    test "a missing exit code is unknown, not zero" do
      assert MiosaCli.exit_code(%{"stdout" => "x"}) == nil
    end
  end

  describe "dead-sandbox classification" do
    test "a vanished sandbox invalidates the warm session" do
      for reason <- [
            "HTTP 404 not found",
            "sandbox destroyed",
            "no such sandbox",
            "Sandbox does not exist"
          ] do
        assert MiosaCli.dead_sandbox_error?(reason), "expected #{reason} to be fatal"
      end
    end

    test "a slow command does not cost us the warm sandbox" do
      # The HTTP backend treats any "timeout" as a dead sandbox, so a long build
      # silently re-provisions. A timeout says nothing about sandbox health.
      refute MiosaCli.dead_sandbox_error?("miosa CLI timed out after 30000ms")
      refute MiosaCli.dead_sandbox_error?("command timeout")
      refute MiosaCli.dead_sandbox_error?("connection closed")
    end
  end

  describe "attached sandboxes" do
    test "create/1 attaches to a configured sandbox_id instead of provisioning" do
      fake_cli()
      write_cli_config(~s({"api_key": "msk_test"}))
      Application.put_env(:optimal_system_agent, :sandbox_miosa_cli, %{sandbox_id: "sbx_mine"})

      assert {:ok, %{id: "sbx_mine", attached: true}} = MiosaCli.create([])
    end

    test "destroy/1 leaves an attached sandbox alone" do
      # The operator (or the CLI) owns a sandbox we merely borrowed.
      assert :ok = MiosaCli.destroy(%{id: "sbx_mine", attached: true})
    end

    test "a blank sandbox_id is treated as unset" do
      fake_cli()
      Application.put_env(:optimal_system_agent, :miosa_cli_config, "/nonexistent/config.json")
      Application.put_env(:optimal_system_agent, :sandbox_miosa_cli, %{sandbox_id: "   "})

      # Falls through to the credential check rather than attaching to "   ".
      assert {:error, reason} = MiosaCli.create([])
      assert reason =~ "not authenticated"
    end
  end

  describe "router registration" do
    test "miosa_cli is a selectable backend" do
      names = Enum.map(Router.list_backends(), & &1.name)
      assert :miosa_cli in names
    end

    test "detection finds the CLI even with no sandbox env vars set" do
      fake_cli()
      write_cli_config(~s({"api_key": "msk_test"}))

      for var <- ["MIOSA_PLATFORM_API_KEY", "E2B_API_KEY", "VERCEL_TOKEN"] do
        assert System.get_env(var) in [nil, ""], "#{var} leaked into this test"
      end

      assert Router.detect_backend() == :miosa_cli
    end
  end
end
