defmodule OptimalSystemAgent.Security.SecretFilePermissionsTest do
  @moduledoc """
  Files that hold API keys must never exist at the process umask, not even
  briefly.

  `File.write!` followed by `File.chmod!` is not a fix for this — it narrows the
  window rather than closing it. Between the two calls the file exists at the
  umask (0644 on a default Linux install) with the key already in it, readable
  by any local process. The mode has to be on the file BEFORE the secret is
  written to it, which is what `System.AtomicFile`'s `:mode` option does: it
  chmods the temp file, writes, then renames into place.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.CLI.Setup
  alias OptimalSystemAgent.Onboarding

  @moduletag :security

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_secrets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    # `write_setup/1` calls `enable_computer_use_if_linux/1`, which APPENDS to
    # the same .env on Linux+X11. That append is a second, separately-fixed
    # write; leaving DISPLAY set would let it mask the mode of the write under
    # test and make these assertions depend on whether the test host has a
    # display.
    prev_display = System.get_env("DISPLAY")
    System.delete_env("DISPLAY")

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      if prev_display, do: System.put_env("DISPLAY", prev_display)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, env_path: Path.join(dir, ".env")}
  end

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  describe "~/.osa/.env" do
    test "is 0600 after an onboarding write", ctx do
      assert :ok =
               Onboarding.write_setup(%{
                 "provider" => "anthropic",
                 "api_key" => "sk-ant-secret",
                 "model" => "claude-opus-5"
               })

      assert File.exists?(ctx.env_path)
      assert mode(ctx.env_path) == 0o600
      assert File.read!(ctx.env_path) =~ "sk-ant-secret"
    end

    test "is 0600 after an upsert of a second provider's key", ctx do
      assert :ok = Onboarding.write_setup(%{"provider" => "anthropic", "api_key" => "sk-ant-1"})

      assert :ok =
               Onboarding.upsert_provider_key(%{
                 "provider" => "openai",
                 "api_key" => "sk-openai-2",
                 "set_active" => false
               })

      assert mode(ctx.env_path) == 0o600

      # And the merge must not have destroyed the first provider's key.
      content = File.read!(ctx.env_path)
      assert content =~ "sk-ant-1"
      assert content =~ "sk-openai-2"
    end

    test "an existing over-permissive .env is tightened, not left as found", ctx do
      File.write!(ctx.env_path, "PRE_EXISTING=1\n")
      File.chmod!(ctx.env_path, 0o644)

      assert :ok = Onboarding.write_setup(%{"provider" => "anthropic", "api_key" => "sk-ant-3"})

      assert mode(ctx.env_path) == 0o600
    end

    test "Setup.save_env writes 0600 and merges rather than clobbering", ctx do
      # This is the path `mix osa.chat` now routes through. It used to rebuild
      # the whole file from three System.get_env lookups with a bare
      # `File.write!` — no mode (0644) and no read-merge (every other key in
      # the file destroyed).
      File.mkdir_p!(ctx.dir)
      Setup.save_env("ANTHROPIC_API_KEY", "sk-ant-keep")
      Setup.save_env("OSA_DEFAULT_PROVIDER", "openai")
      Setup.save_env("GROQ_API_KEY", "gsk-also-keep")

      assert mode(ctx.env_path) == 0o600

      content = File.read!(ctx.env_path)
      assert content =~ "ANTHROPIC_API_KEY=sk-ant-keep"
      assert content =~ "OSA_DEFAULT_PROVIDER=openai"
      assert content =~ "GROQ_API_KEY=gsk-also-keep"
    end
  end
end
