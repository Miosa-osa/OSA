defmodule OptimalSystemAgent.Providers.OllamaCloudCatalogTest do
  @moduledoc """
  Adding an Ollama Cloud model must be ONE edit, and every derived surface must
  actually pick it up.

  Before `Providers.OllamaCloud` existed, a new cloud tag had to be hand-copied
  into six unrelated places (picker list, Registry context table, pricing table,
  the Ollama tool heuristic, the thinking heuristic, cloud-tag detection). The
  predictable result was half-added models: present in the picker, priced at
  $0.00, budgeted at the flat 128k default, and — for "-cloud" suffixed tags —
  not even recognised as cloud, so they were squeezed under the LOCAL num_ctx
  ceiling and `gpt-oss:120b-cloud` was routed to :openai by name.

  These tests lock the derivation down: the catalog is the source, everything
  else reads from it.

  Context windows / capability flags in the catalog were read live from
  `/api/show` through a signed-in local daemon; the assertions below use the
  numbers that probe returned.
  """
  # async: false — the Registry assertions mutate shared app env (:ollama_url,
  # :ollama_num_ctx) and the shared :osa_context_cache ETS table.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Onboarding
  alias OptimalSystemAgent.Providers.Ollama
  alias OptimalSystemAgent.Providers.OllamaCloud
  alias OptimalSystemAgent.Providers.Registry

  @cache :osa_context_cache
  @touched ["kimi-k3:cloud", "gemma4:cloud", "gemma4:31b-cloud", "gpt-oss:120b-cloud"]

  setup do
    if :ets.whereis(@cache) == :undefined do
      :ets.new(@cache, [:set, :public, :named_table])
    end

    prev_url = Application.get_env(:optimal_system_agent, :ollama_url)
    prev_num_ctx = Application.get_env(:optimal_system_agent, :ollama_num_ctx)

    # Closed port => the /api/show probe fails fast, so these tests exercise the
    # STATIC fallback (the value this module owns) rather than a live daemon.
    Application.put_env(:optimal_system_agent, :ollama_url, "http://127.0.0.1:1")

    Enum.each(@touched, &:ets.delete(@cache, &1))

    on_exit(fn ->
      restore(:ollama_url, prev_url)
      restore(:ollama_num_ctx, prev_num_ctx)
      Enum.each(@touched, &:ets.delete(@cache, &1))
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  # Seeding the memo table is how the /api/show probe is mocked — the probe
  # reads this table before issuing any HTTP request.
  defp mock_probe(model, ctx), do: :ets.insert(@cache, {model, ctx})

  defp cloud_picker_models do
    Onboarding.providers_list()
    |> Enum.find(&(&1.id == "ollama_cloud"))
    |> Map.fetch!(:models)
  end

  describe "catalog contents" do
    test "kimi-k3 is registered with its probed 1M window and full capabilities" do
      m = OllamaCloud.model("kimi-k3:cloud")

      assert m.name == "Kimi K3"
      assert m.ctx == 1_048_576
      assert m.ctx_source == :probe
      assert m.tools
      assert m.thinking
      assert m.vision
      assert m.pricing == {3.00, 15.00}
      assert m.requires_subscription =~ "Pro"
    end

    test "glm-5.2 is present exactly once and keeps its real window" do
      assert [%{ctx: 1_000_000, tools: true, thinking: true}] =
               Enum.filter(OllamaCloud.models(), &(&1.id == "glm-5.2:cloud"))
    end

    test "the confirmable gemma4 cloud tags are registered (and no invented ones)" do
      gemma = Enum.filter(OllamaCloud.models(), &String.starts_with?(&1.id, "gemma4"))

      assert Enum.map(gemma, & &1.id) |> Enum.sort() == ["gemma4:31b-cloud", "gemma4:cloud"]
      assert Enum.all?(gemma, &(&1.ctx == 262_144))
      assert Enum.all?(gemma, & &1.vision)
      assert Enum.all?(gemma, & &1.thinking)
      # /api/show reports no audio capability for these tags, whatever the
      # model card claims — the flag follows the daemon.
      refute Enum.any?(gemma, & &1.audio)
    end

    test "every entry is internally consistent" do
      for m <- OllamaCloud.models() do
        assert OllamaCloud.cloud_tag?(m.id), "#{m.id} is not a recognised cloud tag"
        assert is_integer(m.ctx) and m.ctx > 0
        assert m.ctx_source in [:probe, :docs]
        assert is_binary(m.note) and m.note != ""
      end

      ids = Enum.map(OllamaCloud.models(), & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  describe "cloud_tag?/1 (both hosted tag shapes)" do
    test "matches ':cloud' AND size-qualified '-cloud' tags" do
      assert OllamaCloud.cloud_tag?("kimi-k3:cloud")
      assert OllamaCloud.cloud_tag?("gpt-oss:120b-cloud")
      assert OllamaCloud.cloud_tag?("gemma4:31b-cloud")
      # Unknown to this catalog, but still obviously hosted.
      assert OllamaCloud.cloud_tag?("some-future-model:cloud")
    end

    test "does not match local tags or nil" do
      refute OllamaCloud.cloud_tag?("gemma4:12b")
      refute OllamaCloud.cloud_tag?("llama3.2:3b")
      refute OllamaCloud.cloud_tag?(nil)
    end
  end

  describe "the model picker derives from the catalog" do
    test "kimi-k3 appears in the Ollama Cloud picker list" do
      models = cloud_picker_models()
      ids = Enum.map(models, & &1.id)

      assert "kimi-k3:cloud" in ids
      assert "gemma4:cloud" in ids
      assert "gemma4:31b-cloud" in ids
      # glm-5.2 was already offered — verified, not duplicated.
      assert Enum.count(ids, &(&1 == "glm-5.2:cloud")) == 1
    end

    test "the subscription requirement is surfaced in the note the picker renders" do
      entry = Enum.find(cloud_picker_models(), &(&1.id == "kimi-k3:cloud"))

      assert entry.ctx == 1_048_576
      assert entry.tools
      assert entry.note =~ "requires Ollama Pro or Max"
      assert entry.note =~ "credits"
    end

    test "picker entries expose exactly the keys the picker surfaces render" do
      for m <- cloud_picker_models() do
        assert Map.keys(m) |> Enum.sort() == [:ctx, :id, :name, :note, :recommended, :tools]
      end
    end
  end

  describe "Registry context windows derive from the catalog" do
    test "a new cloud model resolves to its catalog window when the probe fails" do
      assert Registry.context_window_info("kimi-k3:cloud") == {:ok, 1_048_576}
      assert Registry.context_window_known?("kimi-k3:cloud", :ollama)
    end

    test "the live probe still WINS over the catalog value" do
      # The fix that landed before this catalog: cloud tags are probed first and
      # the static table is only a fallback. Adding entries must not undo that.
      mock_probe("kimi-k3:cloud", 262_144)
      assert Registry.context_window_info("kimi-k3:cloud") == {:ok, 262_144}
    end

    test "an exact cloud tag beats the family prefix row" do
      # "gemma4" (family, local) and "gemma4:31b-cloud" (hosted) both resolve;
      # the exact hosted key is the one that must answer for the hosted tag.
      assert Registry.context_window_info("gemma4:31b-cloud") == {:ok, 262_144}
    end

    test "'-cloud' tags are not squeezed under the LOCAL num_ctx ceiling" do
      # Regression: ollama_cloud_model?/1 only matched ":cloud", so
      # "gpt-oss:120b-cloud" was treated as local and capped at the KV-cache
      # ceiling — the context meter then read ~16x too high.
      Application.put_env(:optimal_system_agent, :ollama_num_ctx, 8_192)
      assert Registry.effective_context_window("gpt-oss:120b-cloud", :ollama) == 131_072
    end

    test "a hosted tag is attributed to Ollama Cloud, not to a same-named vendor" do
      assert Registry.provider_for_model("kimi-k3:cloud") == :ollama_cloud
      # Previously matched starts_with?("gpt") and resolved to :openai.
      assert Registry.provider_for_model("gpt-oss:120b-cloud") == :ollama_cloud
    end
  end

  describe "pricing derives from the catalog" do
    test "kimi-k3 is priced from its published rates" do
      assert Pricing.rates("kimi-k3:cloud") == {3.00, 15.00}
    end

    test "existing GLM cloud pricing is unchanged" do
      assert Pricing.rates("glm-5.2:cloud") == {0.60, 2.20}
    end
  end

  describe "Ollama tool / thinking gating derives from the catalog" do
    test "catalog capabilities win over the name heuristics" do
      assert Ollama.model_supports_tools?("kimi-k3:cloud")
      assert Ollama.thinking_model?("kimi-k3:cloud")

      # "gemma4" matches no thinking-name heuristic, but /api/show says it
      # thinks — without the catalog it would never be sent `think: true`.
      assert Ollama.model_supports_tools?("gemma4:cloud")
      assert Ollama.thinking_model?("gemma4:cloud")

      # "gpt-oss" matches no tool-capable prefix either.
      assert Ollama.model_supports_tools?("gpt-oss:120b-cloud")
    end

    test "models outside the catalog still fall back to the heuristics" do
      assert Ollama.model_supports_tools?("qwen3:8b")
      refute Ollama.model_supports_tools?("some-unknown-model")
      refute Ollama.thinking_model?("llama3.3:70b")
    end
  end
end
