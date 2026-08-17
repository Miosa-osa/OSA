defmodule OptimalSystemAgent.CLI.SetupTest do
  @moduledoc """
  Regression coverage for the CLI.Setup bug fixes:

    * F3 — `/setup` re-run must be able to switch provider (upsert, not
      append-only-if-absent).
    * F4 — `test_provider/2` must not report success for a provider it never
      actually probed (groq/openrouter/deepseek).
    * Item 1 (audit) — `/setup` (and the REPL first-run, which shares this
      same module) used to be a second, weaker wizard that could not offer
      Ollama Cloud or any model selection at all — `write_config/2` never
      wrote a model, and the provider picker had no `ollama_cloud` entry.
      This left `/setup` unable to reach parity with the good first-run
      wizard (`mix osa.setup.wizard` / `lib/mix/tasks/osa.setup.wizard.ex`).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.CLI.Setup

  @env_path Path.join(Path.join(System.user_home!(), ".osa"), ".env")

  setup do
    original = if File.exists?(@env_path), do: File.read!(@env_path), else: nil

    # Start each test from a clean slate so write_config/* assertions don't
    # accumulate onto the developer's real ~/.osa/.env (leaks provider keys and
    # OSA_MODEL); on_exit restores the original below.
    File.rm(@env_path)

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
    # A garbage key now comes back as `{:key_rejected, msg}` when the provider
    # explicitly said 401/403, and `{:error, msg}` when we merely could not
    # reach it. Both are "not verified" — which is what F4 is about — so these
    # assert on that, not on which of the two the network happened to produce.
    test "an unconfigured/garbage groq key is actually rejected, not blindly :ok" do
      assert Setup.test_provider(:groq, "definitely-not-a-real-key") not in [:ok, :unverified]
    end

    test "an unconfigured/garbage openrouter key is actually rejected, not blindly :ok" do
      assert Setup.test_provider(:openrouter, "definitely-not-a-real-key") not in [
               :ok,
               :unverified
             ]
    end

    test "an unconfigured/garbage deepseek key is actually rejected, not blindly :ok" do
      assert Setup.test_provider(:deepseek, "definitely-not-a-real-key") not in [:ok, :unverified]
    end

    test "a provider with no health-check returns :unverified, not a false :ok" do
      assert Setup.test_provider(:some_future_provider, "any-key") == :unverified
    end
  end

  describe "item 1: /setup reaches parity with the good first-run wizard" do
    test "the provider picker offers ollama_cloud, the recommended provider" do
      assert Enum.any?(Setup.providers(), &(&1.value == :ollama_cloud))
    end

    test "write_config/3 for ollama_cloud (keyed) defaults to the cloud URL and writes key + model" do
      Setup.write_config(:ollama_cloud, "sk-ollama-test", model: "glm-5.2:cloud")

      content = File.read!(@env_path)
      # Runtime provider resolution expects "ollama" (not the literal
      # "ollama_cloud") — OLLAMA_URL is what distinguishes cloud vs local.
      assert content =~ "OSA_DEFAULT_PROVIDER=ollama\n"
      assert content =~ "OLLAMA_URL=https://ollama.com"
      assert content =~ "OLLAMA_API_KEY=sk-ollama-test"
      assert content =~ "OLLAMA_MODEL=glm-5.2:cloud"
    end

    test "write_config/3 for ollama_cloud (keyless local route) writes localhost URL, no API key line" do
      Setup.write_config(:ollama_cloud, nil,
        model: "glm-5.2:cloud",
        base_url: "http://localhost:11434"
      )

      content = File.read!(@env_path)
      assert content =~ "OSA_DEFAULT_PROVIDER=ollama\n"
      assert content =~ "OLLAMA_URL=http://localhost:11434"
      assert content =~ "OLLAMA_MODEL=glm-5.2:cloud"
      refute content =~ "OLLAMA_API_KEY="
    end

    test "write_config/3 writes OSA_MODEL for a keyed provider like anthropic (previously never wrote a model)" do
      Setup.write_config(:anthropic, "sk-ant-test", model: "claude-sonnet-4-6-20260316")

      content = File.read!(@env_path)
      assert content =~ "ANTHROPIC_API_KEY=sk-ant-test"
      assert content =~ "OSA_MODEL=claude-sonnet-4-6-20260316"
    end

    test "write_config/2 (no model) still works exactly as before — arity-2 callers unaffected" do
      Setup.write_config(:ollama, nil)

      content = File.read!(@env_path)
      assert content =~ "OSA_DEFAULT_PROVIDER=ollama\n"
      refute content =~ "OSA_MODEL="
    end

    test "re-running write_config/3 with a different model upserts (replaces), doesn't duplicate" do
      Setup.write_config(:anthropic, "sk-ant-1", model: "claude-haiku-4-5-20251001")
      Setup.write_config(:anthropic, "sk-ant-2", model: "claude-sonnet-4-6-20260316")

      content = File.read!(@env_path)
      assert content =~ "OSA_MODEL=claude-sonnet-4-6-20260316"
      refute content =~ "claude-haiku-4-5-20251001"
      assert content |> String.split("\n") |> Enum.count(&(&1 =~ "OSA_MODEL=")) == 1
    end

    test "validate_provider/2 does not crash for ollama_cloud (no key required for the local route)" do
      assert Setup.validate_provider(:ollama_cloud, nil) == :ok
    end
  end
end
