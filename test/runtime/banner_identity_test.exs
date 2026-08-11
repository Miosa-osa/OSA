defmodule OptimalSystemAgent.Runtime.BannerIdentityTest do
  @moduledoc """
  The startup banner must not be able to lie.

  The bug these tests pin: a fresh launch printed

      │     anthropic / llama3.2:latest  ·  53 tools     │

  above a status bar reading `claude-opus-5`. Two independent defects met there:

    1. **A split pair.** `~/.osa/config.json` is written as a PAIR
       (`{"provider": ..., "model": ...}`) by onboarding, the model picker and
       `POST /models/switch`. Boot-time provider resolution deliberately does not
       read that file, but boot-time MODEL resolution does — so an env-selected
       provider could win while the file's model was still applied to it. Ollama's
       persisted `llama3.2:latest` got stapled onto Anthropic, and because
       `GET /health` is fed by `Runtime.Identity`, the false pair reached the
       status bar, `osa doctor`, `/status` and the agent's own context line.

    2. **A frozen surface.** The banner is written into terminal scrollback once
       and can never be redrawn, so whatever it captured is permanent. The TUI
       side of that is pinned in `welcome.rs` (`banner_identity_matches_status_bar`).

  These tests cover the backend half: a model persisted for provider X must never
  be handed to provider Y, and whatever the tool count claims must be what it
  counts.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Application, as: OsaApp
  alias OptimalSystemAgent.Runtime.Identity
  alias OptimalSystemAgent.Tools.Registry

  @app :optimal_system_agent

  setup do
    prev_model = Application.get_env(@app, :default_model)
    prev_provider = Application.get_env(@app, :default_provider)

    on_exit(fn ->
      restore(:default_model, prev_model)
      restore(:default_provider, prev_provider)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(@app, key)
  defp restore(key, val), do: Application.put_env(@app, key, val)

  describe "model_for_provider/3 — the persisted pair travels together" do
    test "an Ollama-persisted model is never handed to Anthropic" do
      # The exact shape of the reported banner: config.json says ollama, the
      # env/toml picked anthropic. The model belongs to ollama, so it is dropped.
      assert OsaApp.model_for_provider(:anthropic, "llama3.2:latest", "ollama") == nil
    end

    test "a matching provider keeps the model" do
      assert OsaApp.model_for_provider(:ollama, "glm-5.2:cloud", "ollama") == "glm-5.2:cloud"

      assert OsaApp.model_for_provider(:anthropic, "claude-opus-5", "anthropic") ==
               "claude-opus-5"
    end

    test "a config that names no provider is unchanged (old behaviour preserved)" do
      assert OsaApp.model_for_provider(:anthropic, "claude-opus-5", nil) == "claude-opus-5"
      assert OsaApp.model_for_provider(:anthropic, "claude-opus-5", "") == "claude-opus-5"
    end

    test "provider comparison is case/whitespace tolerant" do
      assert OsaApp.model_for_provider(:ollama, "glm-5.2:cloud", " Ollama ") == "glm-5.2:cloud"
    end

    test "a missing model stays missing" do
      assert OsaApp.model_for_provider(:ollama, nil, "ollama") == nil
      assert OsaApp.model_for_provider(:ollama, "", "ollama") == nil
    end
  end

  describe "ollama_env_model/2 — OLLAMA_MODEL is provider-scoped" do
    test "is honoured for the Ollama family" do
      assert OsaApp.ollama_env_model(:ollama, "glm-5.2:cloud") == "glm-5.2:cloud"
      assert OsaApp.ollama_env_model(:ollama_cloud, "glm-5.2:cloud") == "glm-5.2:cloud"
    end

    test "is ignored for every other provider (config/runtime.exs already gates it)" do
      for prov <- [:anthropic, :openai, :groq, :miosa, :openrouter] do
        assert OsaApp.ollama_env_model(prov, "llama3.2:latest") == nil,
               "a stale OLLAMA_MODEL must not reach #{prov}"
      end
    end

    test "a missing value stays missing" do
      assert OsaApp.ollama_env_model(:ollama, nil) == nil
      assert OsaApp.ollama_env_model(:ollama, "") == nil
    end
  end

  describe "Identity — every surface resolves the same coherent pair" do
    test "a configured Anthropic session reports an Anthropic model" do
      Application.put_env(@app, :default_provider, :anthropic)
      Application.put_env(@app, :default_model, "claude-opus-5")

      assert Identity.model() == "claude-opus-5"
      assert Identity.provider() == :anthropic
      assert %{model: "claude-opus-5", provider: :anthropic} = Identity.resolve()
    end

    test "an Anthropic session with no model falls back to Anthropic's catalog default" do
      # This is the state the split-pair fix leaves behind: rather than inheriting
      # somebody else's model, :default_model is simply unset and Identity fills in
      # from the provider's own catalog. It must never be the Ollama last-resort
      # default (providers/ollama.ex "llama3.2:latest").
      Application.put_env(@app, :default_provider, :anthropic)
      Application.delete_env(@app, :default_model)

      model = Identity.model()

      assert is_binary(model) and model != ""

      refute model == "llama3.2:latest",
             "an Anthropic session must never resolve to Ollama's last-resort default"
    end

    test "a configured Ollama session reports its Ollama model" do
      Application.put_env(@app, :default_provider, :ollama)
      Application.put_env(@app, :default_model, "glm-5.2:cloud")

      assert Identity.model() == "glm-5.2:cloud"
      assert Identity.provider() == :ollama
    end

    test "a mid-session switch moves every surface at once" do
      # `POST /models/switch` writes :default_provider + :default_model. Because
      # /health, the context line and `osa doctor` all read Identity, one write
      # moves them together — there is no surface left holding the old value.
      Application.put_env(@app, :default_provider, :ollama)
      Application.put_env(@app, :default_model, "glm-5.2:cloud")
      assert Identity.model() == "glm-5.2:cloud"

      Application.put_env(@app, :default_provider, :anthropic)
      Application.put_env(@app, :default_model, "claude-opus-5")

      assert Identity.model() == "claude-opus-5"
      assert Identity.provider() == :anthropic
      assert Identity.context_line() =~ "claude-opus-5"
      assert Identity.context_line() =~ "anthropic"
      assert %{model: "claude-opus-5"} = Identity.describe()
    end

    test "describe/0 and model/0 cannot disagree" do
      Application.put_env(@app, :default_provider, :anthropic)
      Application.put_env(@app, :default_model, "claude-opus-5")

      %{model: described, provider: prov} = Identity.describe()
      assert described == Identity.model()
      assert prov == Identity.provider()
    end
  end

  describe "no user-facing surface resolves the model on its own" do
    # Every one of these serves a model string to something the user reads: the
    # settings dialog, the dashboard, `GET /models/current` (which marks the
    # highlighted row in the model picker), the model list, and the agent-state
    # panel. Each used to end its own chain at
    # `Application.get_env(.., :ollama_model, "llama3.2:latest")` — a THIRD key,
    # provider-blind, with an Ollama literal at the bottom. That is the mechanism
    # behind stray "llama3.2:latest" sightings on non-Ollama sessions, and it is
    # how a false model fact reached memory once already.
    @identity_surfaces [
      "lib/optimal_system_agent/channels/http/api/settings_routes.ex",
      "lib/optimal_system_agent/channels/http/api/dashboard_routes.ex",
      "lib/optimal_system_agent/channels/http/api/data_routes.ex",
      "lib/optimal_system_agent/channels/http/api/agent_state_routes.ex",
      "lib/optimal_system_agent/channels/http.ex"
    ]

    test "they all go through Runtime.Identity" do
      for path <- @identity_surfaces do
        src = File.read!(path)

        assert src =~ "Runtime.Identity",
               "#{path} serves a model to the user but does not resolve it via Runtime.Identity"

        refute src =~ ~s(:ollama_model, "llama3.2:latest"),
               "#{path} still falls back to the Ollama literal for a non-Ollama session"
      end
    end

    test "the Ollama last-resort literal lives in exactly one place" do
      # providers/ollama.ex is the ONE legitimate home for it: it is Ollama's own
      # `default_model/0`. Anywhere else it is a provider-blind guess.
      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&String.ends_with?(&1, "providers/ollama.ex"))
        |> Enum.filter(&(File.read!(&1) =~ ~s(:ollama_model, "llama3.2:latest")))

      assert offenders == [],
             "these files guess an Ollama model regardless of provider: #{inspect(offenders)}"
    end
  end

  describe "the banner's tool count is the number it claims" do
    test "GET /api/v1/tools == every available registered tool minus model_hidden" do
      # The banner's "N tools" is `tools.len()` from GET /api/v1/tools, which is
      # `Registry.list_tools/0`. It is deliberately NOT the raw registry size: the
      # difference is exactly @model_hidden — harness/orchestration internals the
      # model is never offered (still callable, still findable via tool_search).
      hidden = Registry.model_hidden()

      # The static registry map is the stable denominator: `list_tools_direct/0`
      # additionally applies a live `available?/0` gate (computer_use, browser,
      # code_sandbox come and go with the environment), so counting off it would
      # make this test machine-dependent.
      registered = :persistent_term.get({Registry, :builtin_tools}, %{})
      registered_names = registered |> Map.keys() |> MapSet.new()

      assert map_size(registered) > 0,
             "Tools.Registry published no builtin map — did the GenServer boot?"

      model_visible = MapSet.difference(registered_names, hidden)

      # The three numbers that get confused with each other, pinned apart:
      #   registered      — everything in the registry, harness internals included
      #   model_hidden    — registered + callable, but never in the default toolbox
      #   model_visible   — what GET /api/v1/tools serves and the banner counts
      assert MapSet.size(model_visible) ==
               map_size(registered) - MapSet.size(MapSet.intersection(registered_names, hidden))

      exposed = Registry.list_tools()

      assert length(exposed) > 0,
             "Tools.Registry served no tools — did the GenServer boot?"

      exposed_names = MapSet.new(exposed, & &1.name)

      # Every builtin the endpoint serves is a model-visible one (MCP tools are
      # additive and are not in the builtin map, so they are excluded here).
      builtin_exposed = MapSet.intersection(exposed_names, registered_names)

      assert MapSet.subset?(builtin_exposed, model_visible),
             "the endpoint served a model-hidden tool: " <>
               inspect(MapSet.difference(builtin_exposed, model_visible) |> MapSet.to_list())

      # …and nothing model-visible is dropped except by its own availability gate.
      dropped = MapSet.difference(model_visible, exposed_names)

      for name <- dropped do
        mod = Map.fetch!(registered, name)

        assert Code.ensure_loaded?(mod) and function_exported?(mod, :available?, 0),
               "#{name} vanished from /api/v1/tools without an available?/0 gate to explain it"
      end
    end

    test "no model-hidden tool leaks into the count the banner shows" do
      hidden = Registry.model_hidden()

      leaked =
        Registry.list_tools()
        |> Enum.map(& &1.name)
        |> Enum.filter(&MapSet.member?(hidden, &1))

      assert leaked == [], "model-hidden tools must not be counted: #{inspect(leaked)}"
    end
  end
end
