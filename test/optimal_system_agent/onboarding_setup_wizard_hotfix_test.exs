defmodule OptimalSystemAgent.OnboardingSetupWizardHotfixTest do
  @moduledoc """
  Regression coverage for the Onboarding-side half of the first-run wizard
  hotfix audit (see `test/mix/tasks/osa_setup_wizard_test.exs` for the wizard
  side).

    * C1 — `health_check(%{"provider" => "miosa"})` returns a coming_soon
      result with no `:latency_ms`.
    * M2 — the keyless ollama_cloud route must write OLLAMA_URL=localhost and
      must NOT write OLLAMA_API_KEY, while the keyed route must write
      OLLAMA_URL=https://ollama.com.
    * m6 — the ollama_cloud health-check body no longer defaults to the
      stale nemotron-3-super:cloud model id.

  Uses a TEMP OSA_HOME for every `write_setup/1` call — never the operator's
  real `~/.osa`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Onboarding

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "osa-onboarding-hotfix-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    previous = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", tmp)

    on_exit(fn ->
      if previous, do: System.put_env("OSA_HOME", previous), else: System.delete_env("OSA_HOME")
      File.rm_rf(tmp)
    end)

    %{osa_home: tmp}
  end

  describe "health_check/1 for miosa (C1: no :latency_ms, must not crash callers)" do
    test "returns {:ok, %{status: \"coming_soon\", ...}} with no :latency_ms key" do
      assert {:ok, result} = Onboarding.health_check(%{"provider" => "miosa"})
      assert result.status == "coming_soon"
      refute Map.has_key?(result, :latency_ms)
      assert is_binary(result.message)
    end

    test "the coming_soon result carries a signup_url for the wizard to surface" do
      assert {:ok, %{signup_url: url}} = Onboarding.health_check(%{"provider" => "miosa"})
      assert url =~ "miosa.ai"
    end
  end

  describe "write_setup/1 — ollama_cloud keyless local route (M2)" do
    test "writes OLLAMA_URL=localhost and NO OLLAMA_API_KEY when no key is supplied", %{
      osa_home: osa_home
    } do
      assert :ok =
               Onboarding.write_setup(%{
                 "provider" => "ollama_cloud",
                 "api_key" => nil,
                 "model" => "glm-5.2:cloud",
                 "base_url" => "http://localhost:11434",
                 "channel_tokens" => %{}
               })

      env = File.read!(Path.join(osa_home, ".env"))

      assert env =~ "OLLAMA_URL=http://localhost:11434"
      refute env =~ "ollama.com"
      refute env =~ "OLLAMA_API_KEY="
    end

    test "does NOT clobber a previously stored OLLAMA_API_KEY with the keyless route", %{
      osa_home: osa_home
    } do
      # First write with a key present (the "keyed" route)…
      :ok =
        Onboarding.write_setup(%{
          "provider" => "ollama_cloud",
          "api_key" => "sk-existing-key",
          "model" => "glm-5.2:cloud",
          "base_url" => "https://ollama.com"
        })

      # …then re-run setup and pick the keyless local route. The wizard
      # itself never resends a nil to overwrite an existing key (M2's
      # ollama_cloud_credentials/3 only omits the key when the user actually
      # chose the keyless path), so simulate that: only OLLAMA_URL changes.
      :ok =
        Onboarding.write_setup(%{
          "provider" => "ollama_cloud",
          "api_key" => nil,
          "model" => "glm-5.2:cloud",
          "base_url" => "http://localhost:11434"
        })

      env = File.read!(Path.join(osa_home, ".env"))
      assert env =~ "OLLAMA_URL=http://localhost:11434"
      # maybe_pair/2 drops nil api_key writes — the previously-written key
      # line survives untouched.
      assert env =~ "OLLAMA_API_KEY=sk-existing-key"
    end
  end

  describe "write_setup/1 — ollama_cloud keyed route (M2)" do
    test "writes OLLAMA_URL=https://ollama.com and the key when a key is supplied", %{
      osa_home: osa_home
    } do
      assert :ok =
               Onboarding.write_setup(%{
                 "provider" => "ollama_cloud",
                 "api_key" => "sk-real-key-123",
                 "model" => "glm-5.2:cloud",
                 "base_url" => "https://ollama.com"
               })

      env = File.read!(Path.join(osa_home, ".env"))
      assert env =~ "OLLAMA_URL=https://ollama.com"
      assert env =~ "OLLAMA_API_KEY=sk-real-key-123"
    end
  end

  describe "probe_ollama_local/0 (public API needed by the wizard for M2)" do
    test "is exported (was private before the M2 fix)" do
      assert function_exported?(Onboarding, :probe_ollama_local, 0)
    end

    test "returns a well-formed map regardless of whether a daemon is running" do
      result = Onboarding.probe_ollama_local()
      assert is_boolean(result.reachable)
      assert is_binary(result.url)
      assert is_integer(result.model_count)
    end
  end

  describe "m6: ollama_cloud model default is glm-5.2:cloud everywhere" do
    test "the provider catalog's default_model is glm-5.2:cloud" do
      catalog = Enum.find(Onboarding.providers_list(), &(&1.id == "ollama_cloud"))
      assert catalog.default_model == "glm-5.2:cloud"
    end

    test "the recommended catalog model entry is glm-5.2:cloud" do
      catalog = Enum.find(Onboarding.providers_list(), &(&1.id == "ollama_cloud"))
      recommended = Enum.find(catalog.models, & &1[:recommended])
      assert recommended.id == "glm-5.2:cloud"
    end
  end

  describe "seed_workspace/0 does not resurrect BOOTSTRAP.md for a known user" do
    test "skips BOOTSTRAP.md when USER.md already has a Name line", %{osa_home: osa_home} do
      File.write!(Path.join(osa_home, "USER.md"), "- **Name:** Roberto\n")
      refute File.exists?(Path.join(osa_home, "BOOTSTRAP.md"))

      Onboarding.seed_workspace()

      refute File.exists?(Path.join(osa_home, "BOOTSTRAP.md")),
             "known-user seed must not copy BOOTSTRAP.md back"
    end

    test "still seeds BOOTSTRAP.md on a true first run", %{osa_home: osa_home} do
      File.rm(Path.join(osa_home, "USER.md"))
      File.rm(Path.join(osa_home, "BOOTSTRAP.md"))

      Onboarding.seed_workspace()

      assert File.exists?(Path.join(osa_home, "BOOTSTRAP.md"))
    end
  end

  describe "doctor_checks/0 does not treat a missing BOOTSTRAP.md as an error" do
    test "a named USER.md without BOOTSTRAP.md is not a missing workspace file", %{
      osa_home: osa_home
    } do
      File.write!(Path.join(osa_home, "USER.md"), "- **Name:** Roberto\n")
      File.write!(Path.join(osa_home, "IDENTITY.md"), "- **Name:** OSA\n")
      File.write!(Path.join(osa_home, "SOUL.md"), "ok\n")
      File.write!(Path.join(osa_home, "HEARTBEAT.md"), "ok\n")
      File.write!(Path.join(osa_home, ".env"), "OSA_DEFAULT_PROVIDER=ollama\n")
      File.rm(Path.join(osa_home, "BOOTSTRAP.md"))

      checks = Onboarding.doctor_checks()

      missing =
        Enum.find(checks, fn row -> match?({:error, "Missing workspace files", _}, row) end)

      refute missing
    end
  end
end
