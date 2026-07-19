defmodule OptimalSystemAgent.CLI.SetupTest do
  @moduledoc """
  Regression coverage for the CLI.Setup bug fixes:

    * F3 — `/setup` re-run must be able to switch provider (upsert, not
      append-only-if-absent).
    * F4 — `test_provider/2` must not report success for a provider it never
      actually probed (groq/openrouter/deepseek).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.CLI.Setup

  @env_path Path.join(Path.join(System.user_home!(), ".osa"), ".env")

  setup do
    original = if File.exists?(@env_path), do: File.read!(@env_path), else: nil

    on_exit(fn ->
      case original do
        nil -> File.rm(@env_path)
        content -> File.write!(@env_path, content)
      end
    end)

    :ok
  end

  describe "F3: write_config/2 upserts instead of append-only-if-absent" do
    test "a re-run with a different provider actually switches OSA_DEFAULT_PROVIDER" do
      Setup.write_config(:ollama, nil)
      assert File.read!(@env_path) =~ "OSA_DEFAULT_PROVIDER=ollama"

      # Re-run to switch provider — the old bug silently dropped this because
      # OSA_DEFAULT_PROVIDER already existed in .env.
      Setup.write_config(:anthropic, "sk-ant-test-key")

      content = File.read!(@env_path)
      assert content =~ "OSA_DEFAULT_PROVIDER=anthropic"
      refute content =~ "OSA_DEFAULT_PROVIDER=ollama"
      assert content =~ "ANTHROPIC_API_KEY=sk-ant-test-key"
      # Exactly one OSA_DEFAULT_PROVIDER line — replaced in place, not
      # duplicated.
      assert content |> String.split("\n") |> Enum.count(&(&1 =~ "OSA_DEFAULT_PROVIDER=")) == 1
    end

    test "switching provider again to a key-based one replaces the key too" do
      Setup.write_config(:anthropic, "sk-ant-first")
      Setup.write_config(:anthropic, "sk-ant-second")

      content = File.read!(@env_path)
      assert content =~ "ANTHROPIC_API_KEY=sk-ant-second"
      refute content =~ "sk-ant-first"
      assert content |> String.split("\n") |> Enum.count(&(&1 =~ "ANTHROPIC_API_KEY=")) == 1
    end

    test "unrelated existing keys are preserved across a provider switch" do
      File.mkdir_p!(Path.dirname(@env_path))
      File.write!(@env_path, "TELEGRAM_BOT_TOKEN=keep-me\nOSA_DEFAULT_PROVIDER=ollama\n")

      Setup.write_config(:openai, "sk-openai-key")

      content = File.read!(@env_path)
      assert content =~ "TELEGRAM_BOT_TOKEN=keep-me"
      assert content =~ "OSA_DEFAULT_PROVIDER=openai"
      assert content =~ "OPENAI_API_KEY=sk-openai-key"
    end
  end

  describe "F4: test_provider/2 does not falsely claim verification" do
    test "an unconfigured/garbage groq key is actually rejected, not blindly :ok" do
      assert {:error, _reason} = Setup.test_provider(:groq, "definitely-not-a-real-key")
    end

    test "an unconfigured/garbage openrouter key is actually rejected, not blindly :ok" do
      assert {:error, _reason} = Setup.test_provider(:openrouter, "definitely-not-a-real-key")
    end

    test "an unconfigured/garbage deepseek key is actually rejected, not blindly :ok" do
      assert {:error, _reason} = Setup.test_provider(:deepseek, "definitely-not-a-real-key")
    end

    test "a provider with no health-check returns :unverified, not a false :ok" do
      assert Setup.test_provider(:some_future_provider, "any-key") == :unverified
    end
  end
end
