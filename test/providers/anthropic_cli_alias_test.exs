defmodule OptimalSystemAgent.Providers.AnthropicCliAliasTest do
  @moduledoc """
  A Claude subscriber selects `fable`, not `claude-fable-5`.

  That bare form is the vocabulary `claude --help` documents and what OSA passes
  through to `--model`. Nothing downstream recognised it, so `resolve/1` returned
  nil and every lookup keyed on the model fell through. `Registry.context_window/1`
  missed the catalogue and then PROBED OLLAMA for the context window of a Claude
  model; the TUI divided real usage by a denominator belonging to no model at
  all, and a fresh Fable session opened at "36% ctx" against a 1M window.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.AnthropicModels, as: AM
  alias OptimalSystemAgent.Providers.Registry

  describe "bare CLI aliases resolve" do
    test "every alias the CLI documents maps to a catalogue entry" do
      for {alias_name, canonical} <- AM.cli_aliases() do
        model = AM.resolve(alias_name)

        assert model, "#{alias_name} resolves to nothing — the window lookup will miss"
        assert model.id == canonical
      end
    end

    test "fable is the 1M-context model, not a fallback guess" do
      assert %{id: "claude-fable-5", ctx: 1_000_000} = AM.resolve("fable")
    end

    test "the alias table maps to UNDATED family ids" do
      # Which snapshot an alias resolves to is Claude Code's decision and
      # changes without OSA being involved. A dated mapping here would be a
      # confident lie the first time Anthropic ships a new one.
      for {_alias_name, canonical} <- AM.cli_aliases() do
        refute Regex.match?(~r/-\d{8}$/, canonical),
               "#{canonical} pins a dated snapshot"
      end
    end
  end

  describe "the context meter gets a real denominator" do
    test "fable reports its true window instead of falling through" do
      assert {:ok, 1_000_000} = Registry.context_window_info("fable")
    end

    test "every alias has a KNOWN window" do
      # `context_window_info/1` returning :unknown is what sent the lookup on to
      # the Ollama probe in the first place.
      for {alias_name, _} <- AM.cli_aliases() do
        assert {:ok, tokens} = Registry.context_window_info(alias_name),
               "#{alias_name} has no known window"

        assert tokens > 100_000
      end
    end
  end

  describe "real ids still win over the alias table" do
    test "a full id resolves to itself" do
      assert %{id: "claude-fable-5"} = AM.resolve("claude-fable-5")
      assert %{id: "claude-opus-5"} = AM.resolve("claude-opus-5")
    end

    test "a dated snapshot still resolves by prefix" do
      assert %{id: "claude-haiku-4-5"} = AM.resolve("claude-haiku-4-5-20251001")
    end

    test "an unknown name still resolves to nothing" do
      # The alias table must not become a way to invent models.
      assert AM.resolve("definitely-not-a-model") == nil
    end
  end
end
