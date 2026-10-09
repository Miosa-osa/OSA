defmodule OptimalSystemAgent.Providers.MiosaGatewayTest do
  @moduledoc """
  MIOSA AI Gateway platform mode.

  A MIOSA sandbox run sets (miosa-compute `Engine.AgentAccounts.Injection`,
  `osa_payload/2`):

      MIOSA_AI_GATEWAY_URL   https://api.miosa.ai/api/v1/intelligence
      MIOSA_AI_GATEWAY_KEY   <run-scoped key>
      OSA_DEFAULT_PROVIDER   openai
      OPENAI_BASE_URL        <same URL>
      OPENAI_API_KEY         <same key>

  and the sandbox identity layer also sets `MIOSA_API_KEY` to the sandbox's
  platform identity token, which is NOT an inference key.

  These tests pin that OSA reaches the gateway from the `MIOSA_AI_GATEWAY_*`
  pair alone, from the full platform contract, and that nothing changes when
  the gateway is not configured. The end-to-end block drives a real HTTP
  request through `config/runtime.exs` -> `OpenAICompatProvider` into a local
  stub standing in for the gateway.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Onboarding
  alias OptimalSystemAgent.Providers.{MiosaGateway, OpenAICompat, OpenAICompatProvider}

  @runtime Path.expand("config/runtime.exs", File.cwd!())
  @gateway_url "https://api.miosa.ai/api/v1/intelligence"
  @gateway_key "mgk_run_scoped_test_key"
  @identity_token "sandbox-identity-token-not-an-inference-key"

  # Plus every variable `Onboarding.Provisioned` treats as a configured
  # provider, so a key in the developer's or CI's own environment cannot decide
  # the first-run assertions below.
  @scrubbed Enum.uniq(~w(
                MIOSA_AI_GATEWAY_URL MIOSA_AI_GATEWAY_KEY OSA_DEFAULT_PROVIDER OPENAI_BASE_URL
                OPENAI_API_KEY MIOSA_API_KEY ANTHROPIC_API_KEY GROQ_API_KEY OPENROUTER_API_KEY
                SURPLUS_API_KEY OLLAMA_API_KEY OLLAMA_URL OSA_FALLBACK_CHAIN OSA_MODEL OPENAI_MODEL
                ANTHROPIC_MODEL OPENROUTER_MODEL SURPLUS_MODEL OSA_SKIP_ONBOARDING
                OSA_PLATFORM_ENV_FILE
              ) ++ OptimalSystemAgent.Onboarding.Provisioned.provider_keys())

  @app_keys [
    :openai_url,
    :openai_api_key,
    :openai_model,
    :miosa_ai_gateway_url,
    :default_provider
  ]

  # Run `fun` with exactly `overrides` set among the provider-selection
  # variables, then restore the real process environment.
  defp with_env(overrides, fun) do
    snapshot = System.get_env()
    Enum.each(@scrubbed, &System.delete_env/1)
    # A real /opt/osagent/env.sh on the machine running the suite must not
    # decide first-run either.
    System.put_env("OSA_PLATFORM_ENV_FILE", "/nonexistent/osa-gateway-test/env.sh")
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

  # runtime.exs, read as prod, loads ~/.osa/.env into any UNSET variable. Under
  # a test that file is the developer's own (HOME is fixed at VM start), and an
  # OSA_DEFAULT_PROVIDER in it would silently decide these assertions. Point the
  # loader at a path that cannot exist; fail loudly if the loader ever moves.
  defp runtime_source do
    source = File.read!(@runtime)
    home_env = ~s|Path.expand("~/.osa/.env")|
    assert String.contains?(source, home_env), "runtime.exs no longer loads #{home_env}"
    String.replace(source, home_env, ~s|"/nonexistent/osa-gateway-test/.env"|)
  end

  defp runtime_config(overrides) do
    source = runtime_source()

    with_env(overrides, fn -> Config.Reader.eval!(@runtime, source, env: :prod) end)[
      :optimal_system_agent
    ]
  end

  defp gateway_env do
    %{"MIOSA_AI_GATEWAY_URL" => @gateway_url, "MIOSA_AI_GATEWAY_KEY" => @gateway_key}
  end

  defp platform_contract_env do
    Map.merge(gateway_env(), %{
      "OSA_DEFAULT_PROVIDER" => "openai",
      "OPENAI_BASE_URL" => @gateway_url,
      "OPENAI_API_KEY" => @gateway_key,
      "MIOSA_API_KEY" => @identity_token
    })
  end

  setup do
    previous = Map.new(@app_keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:optimal_system_agent, key, value)
        {key, :error} -> Application.delete_env(:optimal_system_agent, key)
      end)
    end)

    :ok
  end

  describe "from_env/1" do
    test "returns the pair when both variables are set, trimming a trailing slash" do
      env = %{"MIOSA_AI_GATEWAY_URL" => @gateway_url <> "/", "MIOSA_AI_GATEWAY_KEY" => " k "}

      assert MiosaGateway.from_env(&Map.get(env, &1)) == {:ok, %{url: @gateway_url, key: "k"}}
    end

    test "is :none when either variable is missing or blank" do
      for env <- [
            %{},
            %{"MIOSA_AI_GATEWAY_URL" => @gateway_url},
            %{"MIOSA_AI_GATEWAY_KEY" => @gateway_key},
            %{"MIOSA_AI_GATEWAY_URL" => "  ", "MIOSA_AI_GATEWAY_KEY" => @gateway_key},
            %{"MIOSA_AI_GATEWAY_URL" => @gateway_url, "MIOSA_AI_GATEWAY_KEY" => ""}
          ] do
        assert MiosaGateway.from_env(&Map.get(env, &1)) == :none, inspect(env)
        refute MiosaGateway.active?(&Map.get(env, &1))
      end
    end
  end

  describe "config/runtime.exs" do
    test "the gateway pair alone selects :openai pointed at the gateway with its key" do
      cfg = runtime_config(gateway_env())

      assert cfg[:default_provider] == :openai
      assert cfg[:openai_url] == @gateway_url
      assert cfg[:openai_api_key] == @gateway_key
      assert cfg[:miosa_ai_gateway_url] == @gateway_url
    end

    test "the sandbox identity MIOSA_API_KEY does not pull the provider to :miosa" do
      cfg = runtime_config(Map.put(gateway_env(), "MIOSA_API_KEY", @identity_token))

      assert cfg[:default_provider] == :openai
      assert cfg[:openai_api_key] == @gateway_key
    end

    test "the full platform contract resolves to the same gateway endpoint" do
      cfg = runtime_config(platform_contract_env())

      assert cfg[:default_provider] == :openai
      assert cfg[:openai_url] == @gateway_url
      assert cfg[:openai_api_key] == @gateway_key
    end

    test "OPENAI_BASE_URL naming the gateway borrows the gateway key when OPENAI_API_KEY is unset" do
      cfg = runtime_config(Map.put(gateway_env(), "OPENAI_BASE_URL", @gateway_url <> "/"))

      assert cfg[:openai_url] == @gateway_url <> "/"
      assert cfg[:openai_api_key] == @gateway_key
    end

    test "a stray OPENAI_API_KEY is never paired with the gateway URL" do
      cfg = runtime_config(Map.put(gateway_env(), "OPENAI_API_KEY", "sk-real-openai-key"))

      assert cfg[:openai_url] == @gateway_url
      assert cfg[:openai_api_key] == @gateway_key
    end

    test "an explicit OPENAI_BASE_URL elsewhere keeps its own key (existing behavior)" do
      cfg =
        runtime_config(
          Map.merge(gateway_env(), %{
            "OPENAI_BASE_URL" => "https://proxy.example.com/v1",
            "OPENAI_API_KEY" => "proxy-key"
          })
        )

      assert cfg[:openai_url] == "https://proxy.example.com/v1"
      assert cfg[:openai_api_key] == "proxy-key"
    end

    test "an explicit OSA_DEFAULT_PROVIDER still wins over platform mode" do
      cfg = runtime_config(Map.put(gateway_env(), "OSA_DEFAULT_PROVIDER", "anthropic"))

      assert cfg[:default_provider] == :anthropic
      # The gateway stays reachable as :openai, including as a failover target.
      assert cfg[:openai_url] == @gateway_url
      assert :openai in cfg[:fallback_chain]
    end

    test "without the gateway nothing changes" do
      cfg = runtime_config(%{"OPENAI_API_KEY" => "sk-real-openai-key"})

      assert cfg[:default_provider] == :openai
      assert cfg[:openai_api_key] == "sk-real-openai-key"
      refute Keyword.has_key?(cfg, :openai_url)
      assert cfg[:miosa_ai_gateway_url] == nil

      cfg = runtime_config(%{"MIOSA_API_KEY" => "mk-inference"})
      assert cfg[:default_provider] == :miosa
      assert cfg[:openai_api_key] == nil
    end

    test "OSA_MODEL picks the gateway model for the selected provider" do
      cfg = runtime_config(Map.put(gateway_env(), "OSA_MODEL", "glm-5.2:cloud"))

      assert cfg[:openai_model] == "glm-5.2:cloud"
      assert cfg[:default_model] == "glm-5.2:cloud"
    end

    test "the provider's own <PROVIDER>_MODEL outranks OSA_MODEL" do
      cfg =
        runtime_config(
          Map.merge(gateway_env(), %{"OSA_MODEL" => "glm-5.2:cloud", "OPENAI_MODEL" => "kimi-k3"})
        )

      assert cfg[:openai_model] == "kimi-k3"
    end

    test "OSA_MODEL only applies to the provider OSA selected" do
      cfg =
        runtime_config(
          Map.merge(gateway_env(), %{
            "OSA_DEFAULT_PROVIDER" => "anthropic",
            "OSA_MODEL" => "claude-opus-5"
          })
        )

      assert cfg[:anthropic_model] == "claude-opus-5"
      refute Keyword.has_key?(cfg, :openai_model)
    end

    test "with no model env the compiled default model is left alone" do
      cfg = runtime_config(gateway_env())

      for key <- [:openai_model, :anthropic_model, :openrouter_model, :surplus_model] do
        refute Keyword.has_key?(cfg, key), inspect(key)
      end
    end

    test "half a gateway configuration is ignored" do
      cfg = runtime_config(%{"MIOSA_AI_GATEWAY_URL" => @gateway_url})

      assert cfg[:default_provider] != :openai
      refute Keyword.has_key?(cfg, :openai_url)
      assert cfg[:miosa_ai_gateway_url] == nil
    end
  end

  describe "routes_openai?/0 and the Responses-only transport" do
    test "a Responses-only model stays on Chat Completions through the gateway" do
      Application.put_env(:optimal_system_agent, :miosa_ai_gateway_url, @gateway_url)
      Application.put_env(:optimal_system_agent, :openai_url, @gateway_url <> "/")

      assert MiosaGateway.routes_openai?()
      assert OpenAICompatProvider.transport(:openai, "gpt-6-astra") == OpenAICompat
    end

    test "api.openai.com keeps the Responses transport" do
      Application.put_env(:optimal_system_agent, :miosa_ai_gateway_url, nil)
      Application.put_env(:optimal_system_agent, :openai_url, "https://api.openai.com/v1")

      refute MiosaGateway.routes_openai?()

      assert OpenAICompatProvider.transport(:openai, "gpt-6-astra") ==
               OptimalSystemAgent.Providers.OpenAIResponses
    end
  end

  describe "SessionTitler.small_model_opts/0" do
    test "uses the session's own model through the gateway, never OpenAI's catalog pick" do
      Application.put_env(:optimal_system_agent, :default_provider, :openai)
      Application.put_env(:optimal_system_agent, :miosa_ai_gateway_url, @gateway_url)
      Application.put_env(:optimal_system_agent, :openai_url, @gateway_url)

      assert OptimalSystemAgent.Memory.SessionTitler.small_model_opts() == []
    end
  end

  describe "Onboarding.first_run?/0" do
    @tag :tmp_dir
    test "is false in platform mode even with no ~/.osa/.env", %{tmp_dir: home} do
      refute File.exists?(Path.join(home, ".env"))

      with_env(%{"OSA_HOME" => home}, fn -> assert Onboarding.first_run?() end)

      with_env(Map.put(gateway_env(), "OSA_HOME", home), fn ->
        refute Onboarding.first_run?()
      end)
    end

    @tag :tmp_dir
    test "an onboarded ~/.osa/.env still counts without the gateway", %{tmp_dir: home} do
      File.write!(Path.join(home, ".env"), "OSA_DEFAULT_PROVIDER=ollama\n")

      with_env(%{"OSA_HOME" => home}, fn -> refute Onboarding.first_run?() end)
    end
  end

  describe "bin/osa first-run gate" do
    @launcher Path.expand("../../bin/osa", __DIR__)

    # Execute the launcher's own `platform_gateway_configured` definition, so
    # the shell rule is checked by behavior, and it must agree with
    # `MiosaGateway.active?/1` on every case.
    test "platform_gateway_configured agrees with MiosaGateway.active?/1" do
      [function] =
        Regex.run(~r/^platform_gateway_configured\(\) \{\n.*?^\}$/ms, File.read!(@launcher))

      for {url, key} <- [
            {@gateway_url, @gateway_key},
            {@gateway_url, ""},
            {"", @gateway_key},
            {"  ", @gateway_key},
            {@gateway_url, "  "}
          ] do
        env = %{"MIOSA_AI_GATEWAY_URL" => url, "MIOSA_AI_GATEWAY_KEY" => key}

        {_, status} =
          System.cmd("bash", ["-c", function <> "\nplatform_gateway_configured"],
            env: Enum.to_list(env)
          )

        assert status == 0 == MiosaGateway.active?(&Map.get(env, &1)), inspect(env)
      end
    end

    test "the wizard runs only when neither ~/.osa/.env, the gateway nor any provider env configures OSA" do
      assert File.read!(@launcher) =~
               ~s(if ! env_has_provider "$OSA_HOME/.env" && ! platform_gateway_configured && ! onboarding_provisioned; then)
    end
  end

  describe "end to end: runtime.exs -> OpenAICompatProvider -> gateway stub" do
    setup do
      {:ok, server} =
        Bandit.start_link(
          plug: {__MODULE__.GatewayPlug, self()},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Process.exit(server, :normal) end)

      %{gateway_url: "http://127.0.0.1:#{port}/api/v1/intelligence"}
    end

    # The model arrives the way a run would name it: OSA_MODEL, with no
    # explicit per-request model, so the env -> runtime.exs -> provider model
    # resolution is part of what is exercised.
    for model <- ["glm-5.2:cloud", "gpt-6-astra"] do
      test "a #{model} turn reaches <gateway>/chat/completions with the run key", %{
        gateway_url: url
      } do
        cfg =
          runtime_config(%{
            "MIOSA_AI_GATEWAY_URL" => url,
            "MIOSA_AI_GATEWAY_KEY" => @gateway_key,
            "MIOSA_API_KEY" => @identity_token,
            "OSA_MODEL" => unquote(model)
          })

        assert cfg[:default_provider] == :openai
        Enum.each(@app_keys, &Application.put_env(:optimal_system_agent, &1, cfg[&1]))

        assert {:ok, %{content: "pong"}} =
                 OpenAICompatProvider.chat(:openai, [%{role: "user", content: "ping"}])

        assert_receive {:gateway_request, request}
        assert request.method == "POST"
        assert request.path == "/api/v1/intelligence/chat/completions"
        assert request.authorization == "Bearer " <> @gateway_key
        assert request.body["model"] == unquote(model)
      end
    end
  end

  defmodule GatewayPlug do
    @moduledoc false
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, raw, conn} = read_body(conn)

      send(
        test_pid,
        {:gateway_request,
         %{
           method: conn.method,
           path: conn.request_path,
           authorization: conn |> get_req_header("authorization") |> List.first(),
           body: Jason.decode!(raw)
         }}
      )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "id" => "chatcmpl-gateway-stub",
          "object" => "chat.completion",
          "model" => "stub",
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "pong"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}
        })
      )
    end
  end
end
