defmodule OptimalSystemAgent.Runtime.IdentityTest do
  @moduledoc """
  OSA must KNOW its own model, not discover it.

  The bug these tests pin: asked "what model are you", OSA spent 28 seconds and
  three tool calls, guessed `llama3.2:latest` from one config file, and saved
  that guess to memory as a fact — while the TUI status bar displayed the
  correct model the entire time. The bar was right because it renders
  `GET /health`; the agent was wrong because it read an input to /health rather
  than /health's output.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Runtime.Identity

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

  describe "model/0 — the same value the status bar shows" do
    test "returns the reconciled :default_model verbatim" do
      Application.put_env(@app, :default_model, "glm-5.2:cloud")
      Application.put_env(@app, :default_provider, :ollama)

      assert Identity.model() == "glm-5.2:cloud"
    end

    test "agrees with what GET /health puts on the wire" do
      # /health delegates to Identity precisely so these cannot diverge. If
      # someone re-inlines the resolution in http.ex, this fails.
      Application.put_env(@app, :default_model, "some-model:cloud")
      Application.put_env(@app, :default_provider, :ollama)

      assert Identity.model() ==
               OptimalSystemAgent.CLI.Doctor.configured_model_name(:ollama)
    end

    test "never returns nil — degrades to the provider rather than crashing" do
      Application.delete_env(@app, :default_model)
      Application.put_env(@app, :default_provider, :ollama)

      assert is_binary(Identity.model())
      refute Identity.model() == ""
    end
  end

  describe "context_line/1 — what the agent actually sees" do
    test "is a single line and stays small enough for a budget-critical block" do
      Application.put_env(@app, :default_model, "glm-5.2:cloud")
      Application.put_env(@app, :default_provider, :ollama)

      line = Identity.context_line(nil)

      refute String.contains?(line, "\n")
      assert String.starts_with?(line, "- Model: ")
      assert line =~ "glm-5.2:cloud"
      assert line =~ "ollama"
      # Cheap by construction: three tool calls and two wrong guesses cost
      # vastly more than this. Generous ceiling so a longer model id or a
      # version bump does not fail the build.
      assert byte_size(line) < 160
    end

    test "carries OSA's own version, so /version is not a separate discovery" do
      assert Identity.context_line(nil) =~ ~r/OSA v\d/
    end

    test "a live session override wins over the global default" do
      Application.put_env(@app, :default_model, "glm-5.2:cloud")
      Application.put_env(@app, :default_provider, :ollama)

      # Mirrors Loop.swap_provider/3 state: per-session model lives on the Loop
      # struct, not in app env, so the global default must not mask it.
      line = Identity.context_line(%{model: "claude-opus-4", provider: :anthropic})

      assert line =~ "claude-opus-4"
      assert line =~ "anthropic"
      refute line =~ "glm-5.2:cloud"
    end
  end

  describe "resolve/1" do
    test "flags whether the session overrode the global model" do
      Application.put_env(@app, :default_model, "glm-5.2:cloud")
      Application.put_env(@app, :default_provider, :ollama)

      assert %{overridden?: false, model: "glm-5.2:cloud"} = Identity.resolve(nil)

      assert %{overridden?: true, model: "other:cloud"} =
               Identity.resolve(%{model: "other:cloud"})
    end

    test "tolerates partial state maps and keyword lists" do
      Application.put_env(@app, :default_model, "glm-5.2:cloud")
      Application.put_env(@app, :default_provider, :ollama)

      assert %{model: "glm-5.2:cloud"} = Identity.resolve(%{})
      assert %{model: "kw:cloud"} = Identity.resolve(model: "kw:cloud")
    end
  end

  describe "model_source/0 — makes the three-file precedence chain debuggable" do
    test "names a concrete origin rather than a shrug" do
      {source, label} = Identity.model_source()

      assert source in [
               :session_override,
               :config_toml,
               :config_json,
               :env,
               :app_env,
               :catalog_default,
               :unknown
             ]

      assert is_binary(label) and label != ""
    end

    test "attributes an app-env-only model to application config" do
      # A value that matches no file on disk can only have come from a runtime
      # write (/switch, settings route) — it must not be misattributed to a file.
      Application.put_env(@app, :default_model, "sentinel-model-not-in-any-file")
      Application.put_env(@app, :default_provider, :ollama)

      assert {:app_env, _} = Identity.model_source()
    end
  end

  describe "base_url/1 — printable, never leaking a credential" do
    test "strips userinfo and api keys" do
      prev = System.get_env("OLLAMA_URL")
      System.put_env("OLLAMA_URL", "https://secret-key@ollama.com/v1?api_key=abcd1234")

      url = Identity.base_url(:ollama)

      refute url =~ "secret-key"
      refute url =~ "abcd1234"
      assert url =~ "<redacted>"

      if prev, do: System.put_env("OLLAMA_URL", prev), else: System.delete_env("OLLAMA_URL")
    end

    test "is nil for a provider with no known endpoint rather than a guess" do
      assert Identity.base_url(nil) == nil
    end
  end

  describe "context_window/2" do
    test "is honest — :unknown for a model nobody has heard of" do
      assert Identity.context_window("totally-made-up-model-xyz", :ollama) == :unknown
    end
  end

  describe "describe/0" do
    test "returns every field osa doctor needs in one shot" do
      d = Identity.describe()

      assert is_binary(d.model)
      assert is_binary(d.version)
      assert is_binary(d.source_label)
      assert is_atom(d.source)
      assert is_nil(d.context_window) or is_integer(d.context_window)
    end
  end
end
