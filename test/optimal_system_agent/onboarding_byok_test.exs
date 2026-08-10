defmodule OptimalSystemAgent.OnboardingByokTest do
  @moduledoc """
  End-to-end coverage for the "pick Anthropic/OpenAI, paste a key, be running
  on Opus 5 / GPT-5.6" promise — the bring-your-own-key parity with the
  Ollama Cloud flow.

  Covers, per surface:

    * the picker offers the CURRENT models (`claude-opus-5`, `gpt-5.6-*`) and
      no retired id, i.e. `Catalog.apply_sot_overlay/1` still outranks the
      bundled `models_dev.json`;
    * a key entered during onboarding is persisted AND applied live (OS env,
      Application env, and a `CredentialPool` reload — the pool's `get_key/1`
      outranks Application env in `Providers.Anthropic.resolve_auth/0`, so
      without the reload a corrected key never takes effect);
    * `Runtime.Identity` — the single source the status bar and `/health`
      both read — reports the new provider/model with no restart;
    * switching the active provider preserves every other provider's key;
    * a bad key is rejected AT ENTRY with the standard message;
    * `model_list/2` narrows the picker to what the key can actually reach,
      and degrades to the full catalog whenever the probe can't answer.

  All HTTP is intercepted with `Req.Test` — no real network calls.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Onboarding
  alias OptimalSystemAgent.Providers.AnthropicModels
  alias OptimalSystemAgent.Providers.OpenAIModels
  alias OptimalSystemAgent.Runtime.Identity

  @touched_env ~w(
    OSA_DEFAULT_PROVIDER OSA_MODEL
    ANTHROPIC_API_KEY OPENAI_API_KEY OPENAI_BASE_URL
    OLLAMA_API_KEY OLLAMA_MODEL OLLAMA_URL
    GOOGLE_API_KEY GROQ_API_KEY DEEPSEEK_API_KEY
  )

  @touched_app [
    :default_provider,
    :default_model,
    :anthropic_api_key,
    :openai_api_key,
    :openai_url,
    :google_api_key,
    :groq_api_key,
    :deepseek_api_key
  ]

  defp stub_name(tag), do: :"byok_#{tag}_#{System.unique_integer([:positive])}"

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa-byok-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prior_home = System.get_env("OSA_HOME")
    prior_env = Map.new(@touched_env, &{&1, System.get_env(&1)})

    prior_app =
      Map.new(@touched_app, fn k -> {k, Application.get_env(:optimal_system_agent, k)} end)

    System.put_env("OSA_HOME", tmp)

    on_exit(fn ->
      if prior_home, do: System.put_env("OSA_HOME", prior_home), else: System.delete_env("OSA_HOME")

      Enum.each(prior_env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Enum.each(prior_app, fn
        {k, nil} -> Application.delete_env(:optimal_system_agent, k)
        {k, v} -> Application.put_env(:optimal_system_agent, k, v)
      end)

      _ = OptimalSystemAgent.Providers.CredentialPool.reload()
      File.rm_rf(tmp)
    end)

    %{home: tmp, env_path: Path.join(tmp, ".env")}
  end

  # ── The picker offers real, current models ───────────────────────────────

  describe "model picker content" do
    test "anthropic offers claude-opus-5" do
      assert {:ok, models} = Onboarding.model_list("anthropic")
      assert "claude-opus-5" in Enum.map(models, & &1.id)
    end

    test "openai offers the gpt-5.6 family" do
      assert {:ok, models} = Onboarding.model_list("openai")
      ids = Enum.map(models, & &1.id)

      for id <- ~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna) do
        assert id in ids, "picker is missing #{id}"
      end
    end

    test "the anthropic picker contains no retired model id" do
      assert {:ok, models} = Onboarding.model_list("anthropic")

      for %{id: id} <- models do
        refute AnthropicModels.retired?(id),
               "picker offers #{id}, which is past its published retirement date"
      end

      # The specific id the bundled models.dev snapshot used to smuggle in.
      refute Enum.any?(models, &String.starts_with?(&1.id, "claude-3-5-sonnet"))
    end

    test "the catalog overlay — not the bundled snapshot — is what the picker shows" do
      assert {:ok, models} = Onboarding.model_list("anthropic")
      assert MapSet.new(models, & &1.id) == MapSet.new(AnthropicModels.ids())

      assert {:ok, openai} = Onboarding.model_list("openai")
      assert MapSet.new(openai, & &1.id) == MapSet.new(OpenAIModels.ids())
    end
  end

  # ── Key storage + live application ───────────────────────────────────────

  describe "selecting anthropic with a key" do
    test "stores the key, flips the active provider, and offers opus-5 as the model",
         %{env_path: env_path} do
      assert :ok =
               Onboarding.write_setup(%{
                 "provider" => "anthropic",
                 "api_key" => "sk-ant-valid-key",
                 "model" => "claude-opus-5"
               })

      content = File.read!(env_path)
      assert content =~ "ANTHROPIC_API_KEY=sk-ant-valid-key"
      assert content =~ "OSA_DEFAULT_PROVIDER=anthropic"
      assert content =~ "OSA_MODEL=claude-opus-5"

      # ...and the key is applied LIVE, on every path a provider reads it from.
      assert System.get_env("ANTHROPIC_API_KEY") == "sk-ant-valid-key"
      assert Application.get_env(:optimal_system_agent, :anthropic_api_key) == "sk-ant-valid-key"

      assert OptimalSystemAgent.Providers.CredentialPool.get_key(:anthropic) ==
               "sk-ant-valid-key"

      # Identity is the single source the status bar and /health both read.
      assert Identity.provider() == :anthropic
      assert Identity.model() == "claude-opus-5"
    end

    test "a corrected key beats the one the CredentialPool snapshotted at boot" do
      # Simulate "booted with a stale key": the pool caches it.
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-STALE")
      :ok = OptimalSystemAgent.Providers.CredentialPool.reload()
      assert OptimalSystemAgent.Providers.CredentialPool.get_key(:anthropic) == "sk-ant-STALE"

      assert :ok =
               Onboarding.write_setup(%{
                 "provider" => "anthropic",
                 "api_key" => "sk-ant-CORRECTED",
                 "model" => "claude-opus-5"
               })

      assert OptimalSystemAgent.Providers.CredentialPool.get_key(:anthropic) ==
               "sk-ant-CORRECTED"

      assert {:api_key, "sk-ant-CORRECTED"} = OptimalSystemAgent.Providers.Anthropic.resolve_auth()
    end

    test "openai stores its key and a custom base URL that is actually read back",
         %{env_path: env_path} do
      assert :ok =
               Onboarding.write_setup(%{
                 "provider" => "openai",
                 "api_key" => "sk-openai-valid",
                 "model" => "gpt-5.6-sol",
                 "base_url" => "https://proxy.example.test/v1"
               })

      assert File.read!(env_path) =~ "OPENAI_BASE_URL=https://proxy.example.test/v1"

      # `OpenAICompatProvider` dials `:openai_url`, NOT the env var — writing
      # only OPENAI_BASE_URL is how keys used to keep going to api.openai.com.
      assert Application.get_env(:optimal_system_agent, :openai_url) ==
               "https://proxy.example.test/v1"

      assert Identity.provider() == :openai
      assert Identity.model() == "gpt-5.6-sol"
    end
  end

  describe "switching providers" do
    test "other providers' keys are preserved", %{env_path: env_path} do
      :ok =
        Onboarding.write_setup(%{
          "provider" => "anthropic",
          "api_key" => "sk-ant-keep-me",
          "model" => "claude-opus-5"
        })

      :ok =
        Onboarding.write_setup(%{
          "provider" => "openai",
          "api_key" => "sk-openai-now-active",
          "model" => "gpt-5.6-sol"
        })

      content = File.read!(env_path)

      # The .env header promises "keys accumulate; switching provider preserves
      # other providers' keys" — hold it to that.
      assert content =~ "ANTHROPIC_API_KEY=sk-ant-keep-me"
      assert content =~ "OPENAI_API_KEY=sk-openai-now-active"
      assert content =~ "OSA_DEFAULT_PROVIDER=openai"
      refute content =~ "OSA_DEFAULT_PROVIDER=anthropic"

      # Exactly once each — a duplicated key would let the first-wins loader
      # resurrect the old value.
      lines = String.split(content, "\n")
      assert Enum.count(lines, &String.starts_with?(&1, "ANTHROPIC_API_KEY=")) == 1
      assert Enum.count(lines, &String.starts_with?(&1, "OSA_DEFAULT_PROVIDER=")) == 1
    end

    test "switching back to anthropic still finds the preserved key", %{env_path: env_path} do
      :ok = Onboarding.write_setup(%{"provider" => "openai", "api_key" => "sk-openai-x"})

      :ok =
        Onboarding.write_setup(%{
          "provider" => "anthropic",
          "api_key" => "sk-ant-y",
          "model" => "claude-sonnet-5"
        })

      # Switching model only (no key) must never blank the stored key.
      :ok = Onboarding.write_setup(%{"provider" => "anthropic", "model" => "claude-opus-5"})

      content = File.read!(env_path)
      assert content =~ "ANTHROPIC_API_KEY=sk-ant-y"
      assert content =~ "OPENAI_API_KEY=sk-openai-x"
      assert content =~ "OSA_MODEL=claude-opus-5"
    end
  end

  # ── Rejection at entry ───────────────────────────────────────────────────

  describe "an invalid key is caught at entry" do
    test "anthropic 401 -> key_rejected with a clear message" do
      name = stub_name(:ant401)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

      assert {:error, %{verified: :key_rejected, message: message}} =
               Onboarding.health_check(%{
                 "provider" => "anthropic",
                 "api_key" => "sk-ant-typo",
                 "model" => "claude-opus-5",
                 "req_plug" => {Req.Test, name}
               })

      assert message == "API key is invalid or expired."
    end

    test "openai 401 -> key_rejected with a clear message" do
      name = stub_name(:oai401)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

      assert {:error, %{verified: :key_rejected, message: "API key is invalid or expired."}} =
               Onboarding.health_check(%{
                 "provider" => "openai",
                 "api_key" => "sk-typo",
                 "model" => "gpt-5.6-sol",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "a network failure is NEVER reported as a bad key" do
      name = stub_name(:down)
      Req.Test.stub(name, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %{verified: :unverified}} =
               Onboarding.health_check(%{
                 "provider" => "anthropic",
                 "api_key" => "sk-ant-perfectly-fine",
                 "req_plug" => {Req.Test, name}
               })
    end

    test "the in-app /setup wizard classifies the same statuses the same way" do
      alias OptimalSystemAgent.CLI.Setup

      assert Setup.classify_status(200) == :ok
      assert Setup.classify_status(401) == {:key_rejected, "API key is invalid or expired."}
      assert {:key_rejected, _} = Setup.classify_status(403)
      assert {:error, _} = Setup.classify_status(500)
    end
  end

  # ── Probing the account's real model access ──────────────────────────────

  describe "model_list/2 narrows to what the key can actually reach" do
    test "openai: GET /v1/models filters the picker" do
      name = stub_name(:oai_models)

      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => "gpt-5.6-terra"}, %{"id" => "gpt-4o"}]})
      end)

      assert {:ok, models} =
               Onboarding.model_list("openai", api_key: "sk-real", req_plug: {Req.Test, name})

      assert Enum.map(models, & &1.id) |> Enum.sort() == ["gpt-4o", "gpt-5.6-terra"]
    end

    test "anthropic: dated snapshot ids still match the catalog's aliases" do
      name = stub_name(:ant_models)

      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => "claude-opus-5-20260115"}]})
      end)

      assert {:ok, models} =
               Onboarding.model_list("anthropic", api_key: "sk-ant", req_plug: {Req.Test, name})

      assert Enum.map(models, & &1.id) == ["claude-opus-5"]
    end

    test "a failed probe degrades to the full catalog, never an empty picker" do
      name = stub_name(:probe_down)
      Req.Test.stub(name, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:ok, models} =
               Onboarding.model_list("anthropic", api_key: "sk-ant", req_plug: {Req.Test, name})

      assert "claude-opus-5" in Enum.map(models, & &1.id)
      assert length(models) == length(AnthropicModels.ids())
    end

    test "an unrecognised id scheme degrades to the full catalog" do
      name = stub_name(:probe_weird)

      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => "some-vendor/mystery-model"}]})
      end)

      assert {:ok, models} =
               Onboarding.model_list("openai", api_key: "sk-real", req_plug: {Req.Test, name})

      assert length(models) == length(OpenAIModels.ids())
    end

    test "no key means no probe (and no network call)" do
      assert {:ok, models} = Onboarding.model_list("openai")
      assert length(models) == length(OpenAIModels.ids())
    end
  end

  # ── Every provider, not just the two named ones ──────────────────────────

  describe "the whole routable catalog is actually configurable" do
    test "every picker entry maps to a provider the Registry can route" do
      for %{id: id} <- Onboarding.providers_list() do
        assert {:ok, _atom} = Onboarding.known_provider_atom(Onboarding.runtime_provider_id(id)),
               "picker offers '#{id}' but the Registry cannot route it — " <>
                 "a provider you can select but never use is worse than one that is absent"
      end
    end

    test "every key-requiring provider declares where its key is stored" do
      for %{id: id, requires_key: requires} = p <- Onboarding.providers_list(),
          requires == true do
        assert is_binary(p.env_var) and p.env_var != "",
               "provider '#{id}' asks for a key but declares no env var to store it in"
      end
    end

    test "every provider offers at least one model to pick" do
      # `custom` is defined by a URL the user supplies, so it has no catalog
      # until that URL is known — every OTHER entry must offer something.
      for %{id: id} <- Onboarding.providers_list(), id not in ~w(custom miosa ollama_local) do
        assert {:ok, [_ | _]} = Onboarding.model_list(id),
               "provider '#{id}' appears in the picker but offers no models"
      end
    end

    test "every provider has a real health-check endpoint (no silent 'no_endpoint')" do
      for %{id: id} <- Onboarding.providers_list(), id != "custom" do
        name = stub_name(:endpoint)
        Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end)

        result =
          Onboarding.health_check(%{
            "provider" => id,
            "api_key" => "probe",
            "req_plug" => {Req.Test, name}
          })

        refute match?({:error, %{error: "no_endpoint"}}, result),
               "provider '#{id}' has no endpoint to verify a key against"
      end
    end

    test "no provider's key is ever sent to another provider's host" do
      # The exact bug this guards: unknown providers defaulted to
      # api.openai.com, so a Google/Groq/xAI key was POSTed to OpenAI.
      # `custom` has no fixed host, `openai` IS api.openai.com, and `miosa` is
      # gated early access (a static "coming soon", no request at all).
      # `openai_codex` is exempt for a stronger reason than the others: it has
      # no API key at all. Its credential is a subscription token that is only
      # ever read from the credential store and sent to the base URL pinned
      # into that store at sign-in, so there is no key here that COULD be sent
      # to the wrong host. `claude_cli` is exempt for the strongest reason of
      # all: OSA never makes the request. It spawns Anthropic's own CLI, which
      # holds the credential and chooses the host, so OSA has neither a key
      # nor a URL to get wrong. `copilot_cli` is exempt for the same reason:
      # GitHub's CLI makes the request and picks the host.
      #
      # `bedrock` is exempt because it has no fixed host at all: the endpoint
      # is `bedrock.<region>.amazonaws.com`, built from the resolved AWS
      # region, and with no region resolvable the check refuses to run rather
      # than guessing one. That refusal is the correct behaviour — Bedrock has
      # no global endpoint, and guessing `us-east-1` for an account whose
      # models live elsewhere names the wrong problem — but it leaves no
      # request to observe here. The property is covered for bedrock directly
      # in `providers/bedrock_test.exs`, which asserts the host is
      # `bedrock-runtime.<region>.amazonaws.com` and that the SigV4 credential
      # scope names the same region.
      for %{id: id} <- Onboarding.providers_list(),
          id not in ~w(custom openai miosa openai_codex claude_cli copilot_cli bedrock) do
        name = stub_name(:host)
        parent = self()

        Req.Test.stub(name, fn conn ->
          send(parent, {:probed_host, conn.host})
          Plug.Conn.send_resp(conn, 200, "{}")
        end)

        Onboarding.health_check(%{
          "provider" => id,
          "api_key" => "SECRET-#{id}",
          "req_plug" => {Req.Test, name}
        })

        receive do
          {:probed_host, host} ->
            refute host == "api.openai.com",
                   "a '#{id}' key would be sent to api.openai.com"
        after
          0 -> flunk("provider '#{id}' made no verification request at all")
        end
      end
    end

    test "each provider is probed at its own documented host" do
      expected = %{
        "anthropic" => "api.anthropic.com",
        "google" => "generativelanguage.googleapis.com",
        "cohere" => "api.cohere.com",
        "replicate" => "api.replicate.com",
        "groq" => "api.groq.com",
        "xai" => "api.x.ai",
        "deepseek" => "api.deepseek.com",
        "mistral" => "api.mistral.ai",
        "cerebras" => "api.cerebras.ai",
        "fireworks" => "api.fireworks.ai",
        "together" => "api.together.xyz",
        "perplexity" => "api.perplexity.ai",
        "openrouter" => "openrouter.ai",
        "openai" => "api.openai.com"
      }

      for {id, host} <- expected do
        name = stub_name(:host_exact)
        parent = self()

        Req.Test.stub(name, fn conn ->
          send(parent, {:host, conn.host})
          Plug.Conn.send_resp(conn, 200, "{}")
        end)

        Onboarding.health_check(%{
          "provider" => id,
          "api_key" => "probe",
          "req_plug" => {Req.Test, name}
        })

        assert_receive {:host, ^host}, 0, "provider '#{id}' was not probed at #{host}"
      end
    end
  end

  # ── /model routes the picked model to the provider that OWNS it ──────────

  describe "the /model switch resolves the owning provider" do
    test "a model listed under several catalog sections still routes to its owner" do
      # `claude-opus-5` ships under anthropic, azure, azure-cognitive-services,
      # github-copilot, llmgateway, opencode and venice in the models.dev
      # snapshot. `Catalog.find/1` returned whichever the map yielded first —
      # `azure`, which maps to `:openai` — so `/model claude-opus-5` switched
      # the live session to OpenAI carrying an Anthropic model id and 404'd on
      # every turn afterwards. Resolution must prefer the owning provider.
      alias OptimalSystemAgent.Providers.Registry

      assert Registry.provider_for_model("claude-opus-5") == :anthropic
      assert Registry.provider_for_model("claude-sonnet-5") == :anthropic
      assert Registry.provider_for_model("gpt-5.6-sol") == :openai
    end

    test "resolution is stable, not dependent on map iteration order" do
      alias OptimalSystemAgent.Providers.Registry

      for _ <- 1..25 do
        assert Registry.provider_for_model("claude-opus-5") == :anthropic
      end
    end

    test "every model the picker offers routes to a provider that can serve it" do
      alias OptimalSystemAgent.Providers.Registry

      for provider_id <- ~w(anthropic openai google xai cohere),
          {:ok, models} = Onboarding.model_list(provider_id),
          %{id: model_id} <- models do
        expected = elem(Onboarding.known_provider_atom(provider_id), 1)

        assert Registry.provider_for_model(model_id) == expected,
               "picking '#{model_id}' from the #{provider_id} list would switch to " <>
                 "#{inspect(Registry.provider_for_model(model_id))}"
      end
    end
  end

  describe "Google is verified in Google's own wire format" do
    test "the probe posts contents/parts to :generateContent, key in a header" do
      name = stub_name(:google)
      parent = self()

      Req.Test.stub(name, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:google, conn.request_path, Jason.decode!(raw), Map.new(conn.req_headers)})
        Req.Test.json(conn, %{"candidates" => []})
      end)

      assert {:ok, %{verified: :ok}} =
               Onboarding.health_check(%{
                 "provider" => "google",
                 "api_key" => "AIza-secret",
                 "model" => "gemini-3.6-flash",
                 "req_plug" => {Req.Test, name}
               })

      assert_receive {:google, path, body, headers}

      # Gemini's protocol, not OpenAI's: `contents` + `parts`, and
      # `generationConfig` rather than `max_tokens`.
      assert path =~ ":generateContent"
      assert path =~ "gemini-3.6-flash"
      assert [%{"parts" => [%{"text" => "hi"}]} | _] = body["contents"]
      assert body["generationConfig"]["maxOutputTokens"] == 5
      refute Map.has_key?(body, "messages")
      refute Map.has_key?(body, "max_tokens")

      # Key in a header, never a query param — a `?key=` credential leaks into
      # proxy logs and crash reports.
      assert headers["x-goog-api-key"] == "AIza-secret"
      refute path =~ "key="
    end

    test "a rejected Google key is reported as a rejected key" do
      name = stub_name(:google401)
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

      assert {:error, %{verified: :key_rejected, message: "API key is invalid or expired."}} =
               Onboarding.health_check(%{
                 "provider" => "google",
                 "api_key" => "bad",
                 "req_plug" => {Req.Test, name}
               })
    end
  end

  describe "keys accumulate across many switches" do
    test "three consecutive provider switches preserve every earlier key",
         %{env_path: env_path} do
      switches = [
        {"anthropic", "sk-ant-1", "ANTHROPIC_API_KEY"},
        {"openai", "sk-openai-2", "OPENAI_API_KEY"},
        {"google", "AIza-3", "GOOGLE_API_KEY"},
        {"groq", "gsk-4", "GROQ_API_KEY"},
        {"deepseek", "sk-ds-5", "DEEPSEEK_API_KEY"}
      ]

      for {provider, key, _var} <- switches do
        assert :ok = Onboarding.write_setup(%{"provider" => provider, "api_key" => key})
      end

      content = File.read!(env_path)

      for {provider, key, var} <- switches do
        assert content =~ "#{var}=#{key}",
               "#{provider}'s key was lost by a later provider switch"

        assert content |> String.split("\n") |> Enum.count(&String.starts_with?(&1, var <> "=")) ==
                 1,
               "#{var} appears more than once — the first-wins loader could resurrect a stale value"
      end

      # Only the LAST provider is active.
      assert content =~ "OSA_DEFAULT_PROVIDER=deepseek"

      assert content |> String.split("\n")
             |> Enum.count(&String.starts_with?(&1, "OSA_DEFAULT_PROVIDER=")) == 1
    end

    test "a non-OpenAI provider's key is applied live, not just written to disk" do
      assert :ok = Onboarding.write_setup(%{"provider" => "google", "api_key" => "AIza-live"})

      assert System.get_env("GOOGLE_API_KEY") == "AIza-live"
      assert Application.get_env(:optimal_system_agent, :google_api_key) == "AIza-live"
      assert Identity.provider() == :google
    end
  end
end
