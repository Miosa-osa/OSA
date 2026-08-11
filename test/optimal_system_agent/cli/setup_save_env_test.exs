defmodule OptimalSystemAgent.CLI.SetupSaveEnvTest do
  @moduledoc """
  `CLI.Setup.save_env/2` decided replace-vs-append with an UNANCHORED substring
  test (`String.contains?(existing, "KEY=")`) but performed the replacement with
  an ANCHORED regex (`~r/^KEY=.*$/m`). For any key that is a suffix of a key
  already present the two disagree, and the disagreement is silent: the append
  is skipped because `contains?` said the key was there, and the replace is a
  no-op because nothing is anchored at `KEY=`. The key is dropped and the user
  is told the setup succeeded.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.CLI.Setup

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-setup-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev, do: System.put_env("OSA_HOME", prev), else: System.delete_env("OSA_HOME")
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, env: Path.join(dir, ".env")}
  end

  defp env_pairs(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  describe "a key that is a suffix of an existing key" do
    test "API_KEY is written even though ANTHROPIC_API_KEY= is already present", %{env: env} do
      # The exact reported scenario.
      File.write!(env, "ANTHROPIC_API_KEY=sk-ant-existing\n")

      Setup.save_env("API_KEY", "generic-secret")

      pairs = env_pairs(env)

      # The new key must actually land.
      assert pairs["API_KEY"] == "generic-secret",
             "API_KEY was silently dropped; file is:\n#{File.read!(env)}"

      # ...without disturbing the key that merely happened to end with it.
      assert pairs["ANTHROPIC_API_KEY"] == "sk-ant-existing"
    end

    test "the longer existing key is not corrupted by the shorter key's value", %{env: env} do
      File.write!(env, "ANTHROPIC_API_KEY=sk-ant-existing\nOPENAI_API_KEY=sk-openai\n")

      Setup.save_env("API_KEY", "generic")

      pairs = env_pairs(env)
      assert pairs["API_KEY"] == "generic"
      assert pairs["ANTHROPIC_API_KEY"] == "sk-ant-existing"
      assert pairs["OPENAI_API_KEY"] == "sk-openai"
    end

    test "KEY is written when MY_KEY= exists", %{env: env} do
      File.write!(env, "MY_KEY=one\n")
      Setup.save_env("KEY", "two")

      pairs = env_pairs(env)
      assert pairs["KEY"] == "two"
      assert pairs["MY_KEY"] == "one"
    end

    test "a value containing the key name does not suppress the append", %{env: env} do
      # `contains?` also matched when "TOKEN=" appeared inside somebody's VALUE.
      File.write!(env, "NOTE=see TOKEN=elsewhere\n")

      Setup.save_env("TOKEN", "real-token")

      assert env_pairs(env)["TOKEN"] == "real-token"
    end
  end

  describe "ordinary upsert behavior is preserved" do
    test "appends a brand new key to an empty/absent file", %{env: env} do
      Setup.save_env("SLACK_BOT_TOKEN", "xoxb-1")
      assert env_pairs(env)["SLACK_BOT_TOKEN"] == "xoxb-1"
    end

    test "replaces an exact existing key in place, not duplicating it", %{env: env} do
      File.write!(env, "DISCORD_BOT_TOKEN=old\n")
      Setup.save_env("DISCORD_BOT_TOKEN", "new")

      contents = File.read!(env)
      assert env_pairs(env)["DISCORD_BOT_TOKEN"] == "new"

      occurrences =
        contents
        |> String.split("\n", trim: true)
        |> Enum.count(&String.starts_with?(&1, "DISCORD_BOT_TOKEN="))

      assert occurrences == 1, "key was duplicated:\n#{contents}"
    end

    test "leaves unrelated keys and comments alone", %{env: env} do
      File.write!(env, "# a comment\nOTHER=keepme\nANOTHER=alsokeep\n")
      Setup.save_env("NEWKEY", "v")

      pairs = env_pairs(env)
      assert pairs["OTHER"] == "keepme"
      assert pairs["ANOTHER"] == "alsokeep"
      assert pairs["NEWKEY"] == "v"
      assert File.read!(env) =~ "# a comment"
    end

    test "successive saves accumulate rather than overwrite each other", %{env: env} do
      Setup.save_env("EMAIL_ADDRESS", "a@example.com")
      Setup.save_env("EMAIL_PASSWORD", "pw")
      Setup.save_env("EMAIL_IMAP_HOST", "imap.example.com")

      pairs = env_pairs(env)
      assert pairs["EMAIL_ADDRESS"] == "a@example.com"
      assert pairs["EMAIL_PASSWORD"] == "pw"
      assert pairs["EMAIL_IMAP_HOST"] == "imap.example.com"
    end
  end

  describe "the .env is a secrets file" do
    test "is written 0600, never briefly world-readable", %{env: env} do
      Setup.save_env("ANTHROPIC_API_KEY", "sk-ant-secret")
      assert Bitwise.band(File.stat!(env).mode, 0o777) == 0o600
    end

    test "an existing .env symlinked into a dotfiles repo stays a symlink", %{dir: dir, env: env} do
      real = Path.join(dir, "dotfiles.env")
      File.write!(real, "EXISTING=1\n")
      :ok = File.ln_s(real, env)

      Setup.save_env("NEWKEY", "v")

      assert File.lstat!(env).type == :symlink,
             "the user's symlink was replaced by a regular file"

      assert env_pairs(real)["NEWKEY"] == "v"
      assert env_pairs(real)["EXISTING"] == "1"
    end

    test "an unreadable-but-writable .env is not silently rewritten as a one-key stub",
         %{env: env} do
      File.write!(env, "ANTHROPIC_API_KEY=sk-ant-precious\nOPENAI_API_KEY=sk-precious\n")
      # 0200, not 0000: with 0000 the write would fail too and the old code
      # would raise for the wrong reason. Unreadable-but-writable is the case
      # where treating the read error as "no file yet" silently succeeds at
      # wiping every key in the file.
      File.chmod!(env, 0o200)

      on_exit(fn -> File.chmod(env, 0o600) end)

      if File.read(env) == {:error, :eacces} do
        # Treating EACCES as "no file yet" would derive a new file from "" and
        # destroy both keys. Refusing loudly is the only safe answer.
        assert_raise File.Error, fn -> Setup.save_env("GROQ_API_KEY", "gsk-new") end

        File.chmod!(env, 0o600)
        pairs = env_pairs(env)
        assert pairs["ANTHROPIC_API_KEY"] == "sk-ant-precious"
        assert pairs["OPENAI_API_KEY"] == "sk-precious"
      else
        # Running as root (or a permissive FS): chmod 000 is not enforced, so
        # the EACCES branch is unreachable here.
        :ok
      end
    end
  end
end
