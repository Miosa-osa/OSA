defmodule OptimalSystemAgent.Agent.PromptOverridesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.PromptOverrides
  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Providers.Registry, as: ProviderRegistry

  @model "hf.co/Jiunsong/SuperQwen3.8-27b-abliterated-GGUF:Q4_K_M"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "osa-prompt-overrides-#{System.unique_integer([:positive, :monotonic])}"
      )

    path = Path.join(dir, "system_prompts.json")
    prev = Application.get_env(:optimal_system_agent, :prompt_overrides_path)
    Application.put_env(:optimal_system_agent, :prompt_overrides_path, path)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :prompt_overrides_path, prev),
        else: Application.delete_env(:optimal_system_agent, :prompt_overrides_path)

      File.rm_rf(dir)
    end)

    {:ok, path: path}
  end

  describe "persistence" do
    test "set/get/clear round-trips through the JSON file", %{path: path} do
      assert PromptOverrides.get(@model) == nil
      assert :ok = PromptOverrides.set(@model, :inject, "  Always answer in pirate.  ")

      assert %{mode: :inject, text: "Always answer in pirate.", enabled: true} =
               PromptOverrides.get(@model)

      assert File.exists?(path)
      assert {:ok, %{@model => %{"mode" => "inject"}}} = Jason.decode(File.read!(path))

      assert :ok = PromptOverrides.clear(@model)
      assert PromptOverrides.get(@model) == nil
      assert PromptOverrides.list() == %{}
    end

    test "empty text is rejected" do
      assert {:error, :empty_text} = PromptOverrides.set(@model, :replace, "   \n")
      assert PromptOverrides.get(@model) == nil
    end

    test "enable/disable keeps the text and enable on a missing model errors" do
      assert {:error, :not_found} = PromptOverrides.enable(@model, false)
      :ok = PromptOverrides.set(@model, :replace, "You are a toaster.")
      assert :ok = PromptOverrides.enable(@model, false)
      assert %{enabled: false, text: "You are a toaster."} = PromptOverrides.get(@model)
      assert PromptOverrides.effective(@model) == nil
      assert :ok = PromptOverrides.enable(@model, true)
      assert {@model, %{enabled: true}} = PromptOverrides.effective(@model)
    end

    test "a corrupt file degrades to no overrides", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")
      assert PromptOverrides.list() == %{}
      assert PromptOverrides.effective(@model) == nil
    end
  end

  describe "apply/2" do
    test "no override leaves the base untouched" do
      assert {"BASE", :none} = PromptOverrides.apply("BASE", @model)
      assert {"BASE", :none} = PromptOverrides.apply("BASE", nil)
    end

    test "inject appends the operator block after the base" do
      :ok = PromptOverrides.set(@model, :inject, "Speak only in haiku.")
      assert {prompt, {@model, :inject}} = PromptOverrides.apply("BASE", @model)
      assert String.starts_with?(prompt, "BASE\n\n")
      assert prompt =~ "Operator instructions"
      assert String.ends_with?(prompt, "Speak only in haiku.")
    end

    test "replace drops the base entirely" do
      :ok = PromptOverrides.set(@model, :replace, "You are a toaster.")
      assert {"You are a toaster.", {@model, :replace}} = PromptOverrides.apply("BASE", @model)
    end

    test "the wildcard applies to models without their own entry, own entry wins" do
      :ok = PromptOverrides.set(PromptOverrides.all_key(), :inject, "GLOBAL")
      :ok = PromptOverrides.set(@model, :replace, "MINE")

      assert {"MINE", {@model, :replace}} = PromptOverrides.apply("BASE", @model)
      assert {prompt, {"*", :inject}} = PromptOverrides.apply("BASE", "llama3.2:latest")
      assert String.ends_with?(prompt, "GLOBAL")
    end
  end

  describe "provider routing" do
    test "hf.co GGUF tags resolve to local Ollama" do
      assert ProviderRegistry.provider_for_model(@model) == :ollama
      assert ProviderRegistry.provider_for_model("huggingface.co/x/y-GGUF:Q5_K_M") == :ollama
    end
  end

  describe "/system command" do
    # No live session: the command falls back to the node default model, which
    # is fine — `--all` targets the wildcard key regardless.
    test "usage prints on unknown verbs and empty inject" do
      out = capture_io(fn -> Commands.dispatch("system bogus", "no-session") end)
      assert out =~ "/system inject"
      out = capture_io(fn -> Commands.dispatch("system inject", "no-session") end)
      assert out =~ "/system inject"
    end

    test "inject --all saves, status/show/list report it, off/on/clear work" do
      out = capture_io(fn -> Commands.dispatch("system inject --all Be terse.", "no-session") end)
      assert out =~ "Saved for *"
      assert %{mode: :inject, text: "Be terse.", enabled: true} = PromptOverrides.get("*")

      assert capture_io(fn -> Commands.dispatch("system", "no-session") end) =~ "all models"

      assert capture_io(fn -> Commands.dispatch("system show --all", "no-session") end) =~
               "Be terse."

      assert capture_io(fn -> Commands.dispatch("system list", "no-session") end) =~ "inject"

      assert capture_io(fn -> Commands.dispatch("system off --all", "no-session") end) =~ "OFF"
      assert %{enabled: false} = PromptOverrides.get("*")
      assert capture_io(fn -> Commands.dispatch("system on --all", "no-session") end) =~ "ON"
      assert %{enabled: true} = PromptOverrides.get("*")

      assert capture_io(fn -> Commands.dispatch("system clear --all", "no-session") end) =~
               "Cleared"

      assert PromptOverrides.get("*") == nil
    end

    test "replace @file reads the prompt from disk", %{path: path} do
      file = Path.join(Path.dirname(path), "prompt.md")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "You are a toaster.\n")

      out = capture_io(fn -> Commands.dispatch("system replace --all @#{file}", "no-session") end)
      assert out =~ "REPLACES"
      assert %{mode: :replace, text: "You are a toaster."} = PromptOverrides.get("*")

      out =
        capture_io(fn ->
          Commands.dispatch("system replace --all @/nope/missing", "no-session")
        end)

      assert out =~ "cannot read"
    end

    test "inline \\n becomes a real newline; file contents are verbatim", %{path: path} do
      capture_io(fn ->
        Commands.dispatch("system inject --all line one\\nline two", "no-session")
      end)

      assert %{text: "line one\nline two"} = PromptOverrides.get("*")

      file = Path.join(Path.dirname(path), "verbatim.md")
      File.write!(file, "keep \\n literal")
      capture_io(fn -> Commands.dispatch("system replace --all @#{file}", "no-session") end)
      assert %{text: "keep \\n literal"} = PromptOverrides.get("*")
    end

    test "/model shows the override state" do
      assert capture_io(fn -> Commands.dispatch("model", "no-session") end) =~
               ~r/System:.*default/

      :ok = PromptOverrides.set(PromptOverrides.all_key(), :inject, "x")

      assert capture_io(fn -> Commands.dispatch("model", "no-session") end) =~
               "custom (inject, all models)"
    end

    test "/system is registered for autocomplete" do
      assert "system" in Commands.list()
    end
  end
end
