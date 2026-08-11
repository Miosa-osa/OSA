defmodule OptimalSystemAgent.OS.EnvTest do
  # Not async: mutates the real process environment via System.put_env/2.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OS.Env

  @canary "osa-env-scrub-canary-value"

  setup do
    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :env_scrub)
    end)

    :ok
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end

  describe "secret_name?/1 — what counts as a credential" do
    test "provider API keys are secrets" do
      for name <- ~w(ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY XAI_API_KEY
                     GROQ_API_KEY OPENROUTER_API_KEY DEEPSEEK_API_KEY
                     OSA_GATEWAY_TOKEN ANTHROPIC_AUTH_TOKEN) do
        assert Env.secret_name?(name), "#{name} should be scrubbed"
      end
    end

    test "generic secret-shaped names are secrets regardless of vendor" do
      for name <- ~w(MY_APP_SECRET SOME_TOKEN CI_ACCESS_KEY DB_PASSWORD
                     STRIPE_CLIENT_SECRET SERVICE_CREDENTIALS GH_REFRESH_TOKEN) do
        assert Env.secret_name?(name), "#{name} should be scrubbed"
      end
    end

    test "matching is case-insensitive" do
      assert Env.secret_name?("anthropic_api_key")
      assert Env.secret_name?("my_app_secret")
    end

    # THE constraint on this feature: an over-eager scrub breaks every build
    # command, and it does so silently (the toolchain picks a different
    # default rather than erroring).
    test "vars a build/shell legitimately needs are NOT secrets" do
      for name <- ~w(PATH HOME LANG LC_ALL TERM SHELL USER PWD TMPDIR COLORTERM
                     SSH_AUTH_SOCK DISPLAY WAYLAND_DISPLAY
                     CARGO_HOME RUSTUP_HOME GOPATH GOROOT JAVA_HOME
                     NODE_ENV MIX_ENV ERL_LIBS ASDF_DIR VIRTUAL_ENV
                     PKG_CONFIG_PATH LD_LIBRARY_PATH CFLAGS MAKEFLAGS
                     DATABASE_URL REDIS_URL) do
        refute Env.secret_name?(name), "#{name} must NOT be scrubbed"
      end
    end

    # SSH_AUTH_SOCK is the specific reason "AUTH" is not a deny fragment:
    # scrubbing it breaks `git push` over ssh with no useful error.
    test "SSH_AUTH_SOCK survives so git over ssh keeps working" do
      refute Env.secret_name?("SSH_AUTH_SOCK")
    end

    test "operators can add names via config :deny" do
      refute Env.secret_name?("MY_COMPANY_PAT")
      Application.put_env(:optimal_system_agent, :env_scrub, deny: ["MY_COMPANY_PAT"])
      assert Env.secret_name?("MY_COMPANY_PAT")
    end

    test "config :allow wins over every deny rule" do
      assert Env.secret_name?("GITHUB_TOKEN")
      Application.put_env(:optimal_system_agent, :env_scrub, allow: ["GITHUB_TOKEN"])
      refute Env.secret_name?("GITHUB_TOKEN")
    end
  end

  describe "port_env/1 — the Port.open :env overlay" do
    test "unsets every secret currently in the environment" do
      with_env("ANTHROPIC_API_KEY", @canary, fn ->
        entries = Env.port_env()
        assert {~c"ANTHROPIC_API_KEY", false} in entries
      end)
    end

    test "does not mention non-secret vars at all, so they stay inherited" do
      with_env("ANTHROPIC_API_KEY", @canary, fn ->
        names = Env.port_env() |> Enum.map(fn {k, _} -> List.to_string(k) end)
        refute "PATH" in names
        refute "HOME" in names
        refute "TERM" in names
      end)
    end

    test "caller-supplied entries are applied last so a trusted child can be given a value" do
      with_env("ANTHROPIC_API_KEY", @canary, fn ->
        entries = Env.port_env([{"ANTHROPIC_API_KEY", "explicitly-passed"}])
        assert List.last(entries) == {~c"ANTHROPIC_API_KEY", ~c"explicitly-passed"}
      end)
    end

    test "can be disabled by config" do
      with_env("ANTHROPIC_API_KEY", @canary, fn ->
        Application.put_env(:optimal_system_agent, :env_scrub, enabled: false)
        assert Env.port_env() == []
      end)
    end

    test "every entry is charlist-keyed as Port.open requires" do
      with_env("OPENAI_API_KEY", @canary, fn ->
        for {k, v} <- Env.port_env([{"FOO", "bar"}]) do
          assert is_list(k)
          assert v == false or is_list(v)
        end
      end)
    end
  end

  describe "cmd_env/1 — the System.cmd :env shape" do
    test "uses binaries and nil (not false) to unset" do
      with_env("ANTHROPIC_API_KEY", @canary, fn ->
        assert {"ANTHROPIC_API_KEY", nil} in Env.cmd_env()
      end)
    end
  end

  # End-to-end proof against a real child process. This is the test that fails
  # on the original code, where Port.open was called with no :env at all and the
  # child inherited the operator's provider credentials wholesale.
  describe "a real subprocess" do
    @tag :tmp_dir
    test "cannot read the operator's API key", %{tmp_dir: tmp_dir} do
      with_env("ANTHROPIC_API_KEY", @canary, fn ->
        assert System.get_env("ANTHROPIC_API_KEY") == @canary

        out = spawn_and_read("printf '[%s]' \"$ANTHROPIC_API_KEY\"", tmp_dir)

        refute out =~ @canary, "child could read ANTHROPIC_API_KEY: #{inspect(out)}"
        assert out == "[]"
      end)
    end

    @tag :tmp_dir
    test "still sees PATH and HOME so builds keep working", %{tmp_dir: tmp_dir} do
      with_env("ANTHROPIC_API_KEY", @canary, fn ->
        out = spawn_and_read("printf '%s|%s' \"$PATH\" \"$HOME\"", tmp_dir)
        [path, home] = String.split(out, "|", parts: 2)
        assert path == System.get_env("PATH")
        assert home == System.get_env("HOME")
      end)
    end

    @tag :tmp_dir
    test "still sees the user's own non-secret vars", %{tmp_dir: tmp_dir} do
      with_env("MY_BUILD_FLAVOR", "release", fn ->
        assert spawn_and_read("printf '%s' \"$MY_BUILD_FLAVOR\"", tmp_dir) == "release"
      end)
    end
  end

  # Spawns exactly one `sh -c` child under the scrubbed environment and returns
  # its stdout. Deliberately does NOT go through shell_execute so this stays a
  # test of the scrubber alone.
  defp spawn_and_read(command, cwd) do
    sh = OptimalSystemAgent.OS.Shell.executable()

    port =
      Port.open(
        {:spawn_executable, sh},
        [
          :binary,
          :exit_status,
          :hide,
          {:args, OptimalSystemAgent.OS.Shell.port_flags() ++ [command]},
          {:cd, cwd},
          {:env, Env.port_env()}
        ]
      )

    collect(port, [])
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, d}} -> collect(port, [d | acc])
      {^port, {:exit_status, _}} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    after
      10_000 ->
        Port.close(port)
        flunk("child did not exit within 10s")
    end
  end
end
