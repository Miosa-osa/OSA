defmodule OptimalSystemAgent.Providers.CatalogTest do
  @moduledoc """
  Tests for the models.dev-style model catalog: load/normalize and the public
  lookup API. The catalog GenServer boots with the app and loads the bundled
  snapshot (network fetch is disabled in the test env), so these run against
  real bundled data deterministically.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Catalog
  alias OptimalSystemAgent.Providers.Catalog.Model

  describe "load (bundled snapshot)" do
    test "info reports a populated catalog from a local source" do
      info = Catalog.info()
      assert info.providers > 0
      assert info.models > 0
      assert info.source in [:bundled, :cache, :network]
    end

    test "providers/0 includes the routed static providers" do
      providers = Catalog.providers()
      assert is_list(providers)

      for p <- ["openai", "anthropic", "google", "xai", "cerebras"] do
        assert p in providers, "expected #{p} in catalog providers"
      end
    end

    test "models/1 returns %Model{} structs for a known provider" do
      models = Catalog.models("openai")
      assert models != []
      assert Enum.all?(models, &match?(%Model{}, &1))
      assert Enum.all?(models, &(&1.provider_id == "openai"))
    end

    test "models/1 accepts an atom provider id" do
      assert Catalog.models(:anthropic) == Catalog.models("anthropic")
    end

    test "models/1 returns [] for an unknown provider" do
      assert Catalog.models("no_such_provider_xyz") == []
    end
  end

  describe "model/2 + context_window" do
    test "model/2 returns a normalized entry with capability flags" do
      assert %Model{} = m = Catalog.model("openai", "gpt-4o")
      assert m.ctx == 128_000
      assert m.tool_call == true
      assert m.name == "GPT-4o"
    end

    test "reasoning flag is normalized" do
      assert %Model{reasoning: true} = Catalog.model("openai", "o3")
      assert %Model{reasoning: false} = Catalog.model("openai", "gpt-4o")
    end

    test "context_window/2 resolves within a provider" do
      assert Catalog.context_window("openai", "o3") == 200_000
      assert Catalog.context_window("anthropic", "claude-sonnet-4-6") == 1_000_000
    end

    test "context_window/1 resolves across providers" do
      assert Catalog.context_window("gpt-4o") == 128_000
      # grok-4 exists only in the catalog (not the registry's static table).
      assert Catalog.context_window("grok-4") == 256_000
    end

    test "context_window returns nil for unknown models" do
      assert Catalog.context_window("zzz-nonexistent-model") == nil
      assert Catalog.context_window("openai", "zzz-nope") == nil
      assert Catalog.model("openai", "zzz-nope") == nil
    end

    test "bundled snapshot ships NO invented pricing (cost is nil until live fetch)" do
      # The bundled file deliberately omits pricing; the live source is
      # authoritative. Guard against someone hand-adding fake prices offline.
      assert %Model{cost: nil} = Catalog.model("openai", "gpt-4o")
    end
  end

  describe "normalize/1" do
    test "maps models.dev shape into %Model{} and ignores non-provider keys" do
      raw = %{
        "_comment" => "ignore me",
        "acme" => %{
          "id" => "acme",
          "name" => "Acme",
          "models" => %{
            "acme-1" => %{
              "id" => "acme-1",
              "name" => "Acme One",
              "tool_call" => true,
              "reasoning" => false,
              "attachment" => true,
              "cost" => %{"input" => 1.0, "output" => 2.0},
              "limit" => %{"context" => 32_000, "output" => 4_096},
              "modalities" => %{"input" => ["text", "image"], "output" => ["text"]}
            }
          }
        }
      }

      normalized = Catalog.normalize(raw)

      refute Map.has_key?(normalized, "_comment")
      assert %{"acme" => %{"acme-1" => %Model{} = m}} = normalized
      assert m.provider_id == "acme"
      assert m.model_id == "acme-1"
      assert m.ctx == 32_000
      assert m.max_output == 4_096
      assert m.tool_call == true
      assert m.attachment == true
      assert m.cost == %{input: 1.0, output: 2.0, cache_read: nil, cache_write: nil}
      assert m.modalities == %{input: ["text", "image"], output: ["text"]}
    end

    test "tolerates malformed input" do
      assert Catalog.normalize(%{}) == %{}
      assert Catalog.normalize(nil) == %{}
      assert Catalog.normalize(%{"p" => %{"no_models" => true}}) == %{}
    end
  end

  describe "refresh/0" do
    test "is a no-op (disabled) in the test env" do
      assert Catalog.refresh() == {:ok, :disabled}
    end
  end
end
