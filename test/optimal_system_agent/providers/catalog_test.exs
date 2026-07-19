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

  describe "pricing/1,2 and modalities/1,2" do
    test "modalities resolve from the bundled snapshot" do
      assert %{input: inp, output: out} = Catalog.modalities("openai", "gpt-4o")
      assert "text" in inp
      assert "image" in inp
      assert "text" in out

      assert Catalog.modalities("gpt-4o") == Catalog.modalities("openai", "gpt-4o")
      assert Catalog.modalities("zzz-nope") == nil
    end

    test "pricing is nil for the bundled snapshot (no invented prices)" do
      assert Catalog.pricing("openai", "gpt-4o") == nil
      assert Catalog.pricing("gpt-4o") == nil
    end
  end

  describe "small_model/1 heuristic" do
    test "offline (no pricing) prefers a small-named model per provider" do
      # Bundled snapshot ships no cost, so the offline path uses the name regex.
      small_re = ~r/\b(nano|flash|lite|mini|haiku|small|fast)\b/

      assert %Model{model_id: "claude-haiku-4-5"} = Catalog.small_model("anthropic")

      assert %Model{model_id: openai_small} = Catalog.small_model("openai")
      assert Regex.match?(small_re, String.downcase(openai_small)),
             "expected a small-named openai model, got #{openai_small}"
    end

    test "returns nil for a provider with no models" do
      assert Catalog.small_model("no_such_provider_xyz") == nil
    end

    test "cost + age scoring picks the cheapest small model when priced" do
      raw = %{
        "acme" => %{
          "id" => "acme",
          "name" => "Acme",
          "models" => %{
            "acme-big" => %{
              "name" => "Acme Big",
              "release_date" => "2025-01-01",
              "cost" => %{"input" => 10.0, "output" => 30.0},
              "limit" => %{"context" => 200_000, "output" => 8_192},
              "modalities" => %{"input" => ["text"], "output" => ["text"]}
            },
            "acme-mini" => %{
              "name" => "Acme Mini",
              "release_date" => "2025-06-01",
              "cost" => %{"input" => 0.1, "output" => 0.3},
              "limit" => %{"context" => 128_000, "output" => 8_192},
              "modalities" => %{"input" => ["text"], "output" => ["text"]}
            }
          }
        }
      }

      norm = Catalog.normalize(raw)
      acme = Map.fetch!(norm, "acme")

      # Drive the same scoring the public getter uses, on an isolated fixture
      # (avoids mutating the shared, app-owned ETS catalog).
      chosen =
        acme
        |> Map.values()
        |> Enum.filter(fn m -> m.cost && m.cost.input + m.cost.output > 0 end)
        |> Enum.min_by(fn m -> m.cost.input + m.cost.output end)

      assert chosen.model_id == "acme-mini"
    end
  end

  describe "cache_fresh?/2 (TTL via file mtime)" do
    setup do
      path = Path.join(System.tmp_dir!(), "osa-catalog-ttl-#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"ok":true}))
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "a just-written file is fresh; an old-mtime file is stale", %{path: path} do
      assert Catalog.cache_fresh?(path, 60_000)

      # Backdate mtime far into the past → stale under a 5-min TTL.
      :ok = File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
      refute Catalog.cache_fresh?(path, 5 * 60 * 1000)
    end

    test "a missing file is never fresh" do
      assert Catalog.cache_fresh?("/no/such/osa-cache.json", 60_000) == false
      assert Catalog.cache_fresh?(nil, 60_000) == false
    end
  end

  describe "load_chain/3 fallback (cache → bundled → baked)" do
    test "falls back to the inline baked snapshot when cache + bundled are missing" do
      {raw, source} = Catalog.load_chain("/no/cache.json", "/no/bundled.json")
      assert source == :baked

      norm = Catalog.normalize(raw)
      # Baked snapshot always covers the glm/anthropic/openai/ollama families.
      assert %Model{ctx: 200_000} = norm["anthropic"]["claude-sonnet-4-6"]
      assert Map.has_key?(norm, "zhipuai")
      assert Map.has_key?(norm, "ollama")
    end

    test "prefers the bundled file when present and cache is absent", %{} do
      bundled = Application.get_env(:optimal_system_agent, :models_path) ||
                  Path.join([to_string(:code.priv_dir(:optimal_system_agent)), "catalog", "models_dev.json"])

      {_raw, source} = Catalog.load_chain("/no/cache.json", bundled)
      assert source == :bundled
    end
  end

  describe "fetch_catalog/2 (injected fetcher — no network)" do
    test "parses a models.dev-shaped body from a stub fetcher" do
      fixture = %{
        "openai" => %{"id" => "openai", "name" => "OpenAI", "models" => %{}}
      }

      stub = fn "http://stub/api.json" -> {:ok, fixture} end
      assert {:ok, ^fixture} = Catalog.fetch_catalog("http://stub/api.json", stub)
    end

    test "returns the error when the fetcher fails (caller keeps its snapshot)" do
      failing = fn _url -> {:error, :nxdomain} end
      assert {:error, :nxdomain} = Catalog.fetch_catalog("http://x", failing)
    end

    test "rejects a non-map body and a raising fetcher without crashing" do
      assert {:error, :unexpected_body} = Catalog.fetch_catalog("u", fn _ -> {:ok, "nope"} end)
      assert {:error, {:fetcher_raised, _}} = Catalog.fetch_catalog("u", fn _ -> raise "boom" end)
    end
  end
end
