defmodule OptimalSystemAgent.Providers.AddedModelCompletenessTest do
  @moduledoc """
  A model is not "added" until every per-model fact resolves.

  Fourteen defects of one shape were found in a single night: a capability
  decided by a name-matching heuristic or a hardcoded table, which then silently
  disables something for every model released after the table was written.
  Adding a model badly is the cheapest way to reproduce that class, because the
  failure is never an error — it is a `nil` that some caller reads as a default.

  The concrete precedents this file exists to prevent recurring:

    * `anthropic/claude-opus-5` billed at Claude **3** Opus's rate (2.487x).
    * `glm-5.2:cloud` — the DEFAULT model — billed at GLM-**4.7**'s rate, 2.4x
      low on input, with `confidence/1` reporting `:exact` throughout.
    * `glm-4.7:cloud` resolving to an `:unknown` context window, which
      **disabled compaction entirely**.
    * `reasoning_model?/1` answering false for OpenRouter's own default, so no
      `reasoning_effort` was ever sent and the timeout stayed at 120s.
    * 39 `:vision` flags across four catalogues that nothing read.

  So each model added on 2026-08-15 is asserted here against the FULL tuple —
  price (and that the price is published, not guessed), context window, output
  ceiling, reasoning, effort vocabulary, vision, tools — rather than against
  whichever one fact the adder happened to remember.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Pricing

  alias OptimalSystemAgent.Providers.{
    Anthropic,
    AnthropicModels,
    GoogleModels,
    ModelLimits,
    OpenAICodex,
    OpenAICompat,
    OpenAICompatProvider,
    OpenAIModels,
    Registry,
    SurplusModels,
    XAIModels,
    ZaiModels
  }

  describe "Grok 4.6" do
    test "every published fact resolves, under both the bare and gateway id" do
      for id <- ["grok-4.6", "x-ai/grok-4.6"] do
        assert Pricing.rates(id) == {2.00, 6.00}, "#{id}: xAI publishes $2.00/$6.00 per 1M"

        assert Pricing.confidence(id) == :exact,
               "#{id}: priced by GUESS. A model in the catalog must never reach the " <>
                 "@families substring fallback — that is the claude-opus-5 defect."

        assert XAIModels.context_window(id) == 500_000
        assert XAIModels.reasoning?(id)
        assert XAIModels.capability(id, :vision), "grok-4.6 takes image input"
        assert XAIModels.capability(id, :tools)
      end
    end

    test "the effort ladder reaches it and is clamped to what it accepts" do
      # A reasoning model that returns nil here sends no `reasoning_effort`
      # AND drops from the 600s timeout to 120s — the OpenRouter-default bug.
      for effort <- [:low, :medium, :high, :max, :ultra] do
        assert XAIModels.reasoning_effort("grok-4.6", effort) in ["low", "medium", "high"],
               "effort #{inspect(effort)} produced an unsupported value"
      end

      # 4.6 publishes no "none", so an off request must raise into the floor
      # rather than emit a level xAI will reject.
      assert XAIModels.reasoning_effort("grok-4.6", :off) == "low"
    end

    test "no max output is invented" do
      # xAI publishes no output ceiling for ANY model; its 128,000
      # `max_completion_tokens` is a request default, not a cap. `nil` means
      # "do not clamp" and is the correct answer, not a missing one.
      assert ModelLimits.max_output("grok-4.6") == nil
    end

    test "the 200k tier cliff is recorded, not just described in prose" do
      assert XAIModels.long_context_threshold() == 200_000

      assert XAIModels.long_context_pricing()["grok-4.6"] == {4.00, 12.00},
             "xAI rebills the WHOLE request at 2x once the prompt reaches 200k"
    end

    test "its cached-input rate is not the generic 0.1x multiplier" do
      # 4.6 and 4.5 share a $2.00 input rate and read cache at different
      # prices, so no single multiplier can be right for both. Pricing applies
      # 0.1x to everything; these are the real published figures.
      assert XAIModels.cache_read_rate("grok-4.6") == 0.50
      assert XAIModels.cache_read_rate("grok-4.5") == 0.30
    end

    test "it is the default and the one recommended xAI model" do
      assert XAIModels.default_model() == "grok-4.6"
      assert Enum.count(XAIModels.models(), & &1.recommended) == 1
      assert XAIModels.default_model() in XAIModels.ids()
    end
  end

  describe "xAI aliases that are not suffixes of the id they name" do
    # `grok-4.20` and `grok-code-fast-1` are ids xAI documents and actively
    # steers users toward, and both are SHORTER than the model they resolve to
    # — so the prefix match failed in the only direction that mattered and both
    # costed every turn at $0.00.
    test "a documented alias prices and budgets like the model it serves" do
      for {alias_id, canonical} <- [
            {"grok-4.20", "grok-4.20-0309-reasoning"},
            {"grok-4.20-reasoning", "grok-4.20-0309-reasoning"},
            {"grok-code-fast-1", "grok-build-0.1"},
            {"grok-build-latest", "grok-4.5"}
          ] do
        assert Pricing.rates(alias_id) == Pricing.rates(canonical),
               "#{alias_id} does not price as #{canonical} — it serves that model"

        assert Pricing.confidence(alias_id) == :exact, "#{alias_id} priced by guess"

        assert XAIModels.context_window(alias_id) == XAIModels.context_window(canonical),
               "#{alias_id} would be budgeted against the wrong window"
      end
    end
  end

  describe "GLM — the default family, which had no catalog at all" do
    test "GLM-5.2 resolves under every spelling OSA actually sends" do
      # Bare, gateway-prefixed, Ollama cloud tag. Each arrives from a different
      # route and each used to be handled — or not — by a different table.
      for id <- ["glm-5.2", "glm-5.2:cloud"] do
        assert Pricing.rates(id) == {1.40, 4.40},
               "#{id}: Z.ai publishes $1.40/$4.40. {0.60, 2.20} is GLM-4.7's rate."

        assert Pricing.confidence(id) == :exact
        assert ZaiModels.context_window(id) == 1_048_576
        assert ModelLimits.max_output(id) == 131_072
        assert ZaiModels.reasoning?(id)
        assert ZaiModels.capability(id, :tools)
      end
    end

    test "the whole family reasons, by catalog rather than by name shape" do
      # Nothing in `OpenAICompat.name_reasoning?/1` matches "glm" — recognition
      # falls entirely to a `Catalog` ETS table that is EMPTY under mix test,
      # empty before boot, and empty for any consumer that never starts the
      # supervision tree. This module is compile-time data and cannot be
      # unavailable, which is the whole point of it existing.
      for m <- ZaiModels.models() do
        assert ZaiModels.reasoning?(m.id), "#{m.id} must be recognised as reasoning"
        assert ZaiModels.reasoning?("z-ai/" <> m.id), "the gateway spelling must resolve too"
      end
    end

    test "reasoning_effort is offered ONLY where Z.ai documents it" do
      # Z.ai states the parameter is "only supported by GLM-5.2". Emitting a
      # level for 5.1 would make the ladder look wired when the model ignores
      # it — the same illusion as sending thinkingBudget to a Gemini 3 model.
      assert ZaiModels.reasoning_effort("glm-5.2", :high) == "high"
      assert ZaiModels.reasoning_effort("glm-5.2", :ultra) == "max"
      assert ZaiModels.reasoning_effort("glm-5.2", :minimal) == "minimal"

      for id <- ["glm-5.1", "glm-5", "glm-4.7"] do
        assert ZaiModels.reasoning_effort(id, :high) == nil,
               "#{id} takes no reasoning_effort — Z.ai documents it for 5.2 only"
      end
    end

    test "an OFF effort disables thinking explicitly rather than by omission" do
      # `thinking.type` defaults to "enabled", so omitting the object leaves
      # reasoning ON — the DeepSeek V4 trap, same shape.
      assert ZaiModels.thinking_params("glm-5.2", :off) ==
               %{"thinking" => %{"type" => "disabled"}}

      assert %{"thinking" => %{"type" => "enabled"}, "reasoning_effort" => "high"} =
               ZaiModels.thinking_params("glm-5.2", :high)

      # 5.1 gets the object but no effort key.
      assert ZaiModels.thinking_params("glm-5.1", :high) ==
               %{"thinking" => %{"type" => "enabled"}}

      assert ZaiModels.thinking_params("claude-opus-5", :high) == %{}
    end

    test "vision belongs to the v-line only, and the flag is reachable" do
      # `:vision` flags were dead data until they were wired into ImageBudget.
      # Now a wrong one sends an image to a model that cannot see it.
      for id <- ["glm-5.2", "glm-5.1", "glm-4.7", "glm-5"] do
        refute ZaiModels.capability(id, :vision), "#{id} is a text-only model"
      end

      for id <- ["glm-5v-turbo", "glm-4.6v"] do
        assert ZaiModels.capability(id, :vision), "#{id} is a multimodal model"
      end
    end

    test "a v-suffixed id is not swallowed by its text-model prefix" do
      # `starts_with?("glm-4.6v", "glm-4.6")` is true, so a naive prefix match
      # resolves the vision model to the text one and drops its images.
      assert ZaiModels.resolve("glm-4.6v").id == "glm-4.6v"
      assert ZaiModels.resolve("glm-4.7-flash").id == "glm-4.7-flash"
    end

    test "GLM-5.3 is absent until Z.ai ships an API id for it" do
      # Announced, and reachable through the GLM Coding Plan — but Z.ai's docs
      # say verbatim "The GLM-5.3 API is coming soon", publish no model id and
      # no price, and ollama.com/library/glm-5.3 is a 404. A model with no id
      # cannot be added; one with no price is exactly what the family guess
      # mis-bills.
      refute "glm-5.3" in ZaiModels.ids()

      assert ZaiModels.resolve("glm-5.3") == nil,
             "glm-5.3 must not silently resolve to glm-5 and inherit its window and price"
    end
  end

  describe "Gemini 3.7 Flash" do
    test "every fact resolves" do
      assert Pricing.rates("gemini-3.7-flash") == {0.75, 3.75}
      assert Pricing.confidence("gemini-3.7-flash") == :exact
      assert GoogleModels.context_window("gemini-3.7-flash") == 1_048_576
      assert ModelLimits.max_output("gemini-3.7-flash") == 65_536

      m = GoogleModels.model("gemini-3.7-flash")
      assert m.vision and m.audio and m.tools
    end

    test "the effort ladder reaches it" do
      # `thinking: :none` here would silently no-op the entire Agent.Effort
      # ladder on Google's newest model — the exact failure GoogleModels was
      # written to end when the default moved to 3.6 Flash.
      assert GoogleModels.model("gemini-3.7-flash").thinking == :level

      for level <- ["minimal", "low", "medium", "high"] do
        assert level in GoogleModels.model("gemini-3.7-flash").levels
      end
    end

    test "the introductory rate is recorded, not the list rate" do
      # Google runs dated promos and footnotes the expiry. 3.6 Flash was
      # recorded at its {1.50, 7.50} LIST price while Google billed half that,
      # so every Gemini cost OSA reported was 2x high and labelled `:exact`.
      # Both current Flash models revert to list on 2027-01-01.
      assert Pricing.rates("gemini-3.6-flash") == {0.75, 3.75}

      refute Pricing.rates("gemini-3.6-flash") == {1.50, 7.50},
             "that is the post-2027-01-01 list rate, not the rate billed today"
    end

    test "adding it did not move the Google default" do
      # Moving a provider default is a behaviour change for every existing
      # user, and is an editorial decision rather than a consequence of a
      # catalog edit. 3.7 Flash is offerable but not yet the default.
      assert GoogleModels.default_model() == "gemini-3.6-flash"
      assert Enum.count(GoogleModels.models(), & &1.recommended) == 1
    end
  end

  describe "Claude Opus 5.5 — released 2026-09-22" do
    test "every published fact resolves, under the native id and the OpenRouter dotted spelling" do
      # `Pricing` strips a gateway's `vendor/` prefix before it ever asks the
      # catalogue (`lookup_keys/1`), so both spellings price correctly here.
      # `AnthropicModels` itself is never handed a vendor-prefixed string in
      # production — Registry strips that before consulting the catalogue —
      # so its own facts are asserted on the bare id only, same as every
      # other `describe` block in this file.
      for id <- ["claude-opus-5-5", "anthropic/claude-opus-5.5"] do
        assert Pricing.rates(id) == {4.00, 20.00},
               "#{id}: Anthropic publishes $4.00/$20.00 per 1M"

        assert Pricing.confidence(id) == :exact,
               "#{id}: priced by GUESS. A model in the catalog must never reach the " <>
                 "@families substring fallback — that is the claude-opus-5 defect."
      end

      assert AnthropicModels.context_window("claude-opus-5-5") == 1_000_000
      assert AnthropicModels.max_output("claude-opus-5-5") == 128_000
      assert AnthropicModels.capability("claude-opus-5-5", :vision)
      assert AnthropicModels.capability("claude-opus-5-5", :tools)

      # The dotted OpenRouter spelling resolves to the SAME model, not to its
      # shorter sibling `claude-opus-5` — `claude-opus-5` is a literal string
      # prefix of `claude-opus-5.5`, which is exactly the shape that used to
      # mis-resolve before `AnthropicModels.resolve/1` learned to try the
      # dot→dash rewrite as an exact match first.
      assert AnthropicModels.resolve("claude-opus-5.5").id == "claude-opus-5-5"

      assert Registry.provider_for_model("claude-opus-5-5") == :anthropic
    end

    test "cache reads bill at the published 5% rate, not the generic 10% multiplier" do
      # Opus 5.5 reads cache at $0.20/1M against a $4.00 input rate — 0.05x.
      # Every other current Claude model is 0.1x (Opus 5 reads at $0.50/1M on
      # its $5.00 input rate); the generic multiplier would double-bill a
      # 5.5 cache read to $0.40/1M.
      assert Pricing.cache_read_rate("claude-opus-5-5") == {0.20, :published}
      assert Pricing.cache_read_rate("claude-opus-5") == {0.50, :multiplier}
    end

    test "thinking cannot be disabled — every path that builds one lands on adaptive" do
      assert AnthropicModels.thinking_mode("claude-opus-5-5") == :adaptive

      # `LLMClient.thinking_decision/1` is what a live turn actually calls.
      assert LLMClient.thinking_decision(%{provider: :anthropic, model: "claude-opus-5-5"}) ==
               {%{type: "adaptive"}, :adaptive}

      # Belt-and-braces: a stray `{type: "enabled", budget_tokens: N}` — the
      # exact shape that is a hard 400 on this model at every effort level —
      # is coerced to adaptive rather than forwarded as-is.
      assert Anthropic.normalize_thinking(
               %{type: "enabled", budget_tokens: 4096},
               "claude-opus-5-5"
             ) == %{type: "adaptive"}

      # And the body-builder only ever emits `budget_tokens` for a `:budget`
      # config — never for the `:adaptive` shape this model always produces
      # (which carries `display: "summarized"`, never a token count).
      assert Anthropic.maybe_add_thinking(%{}, %{type: "adaptive"}) ==
               %{thinking: %{type: "adaptive", display: "summarized"}}

      refute AnthropicModels.supports_prefill?("claude-opus-5-5"),
             "Opus 5.5 rejects a trailing assistant message with a 400 — same as Opus 5"
    end

    test "effort is always sent explicitly, at the full 5-level ladder" do
      # Anthropic's own default moved to `medium` on this model (Opus 5
      # defaulted `high`) — irrelevant to OSA's wire behaviour, because
      # `Anthropic.build_output_config/2` puts an explicit value on every
      # request rather than omitting the field and trusting the model's own
      # default either way.
      assert AnthropicModels.effort_levels("claude-opus-5-5") == ~w(low medium high xhigh max)

      for {level, wire} <- [
            {:fast, "low"},
            {:medium, "medium"},
            {:high, "high"},
            {:xhigh, "xhigh"},
            {:ultra, "max"}
          ] do
        assert Anthropic.build_output_config("claude-opus-5-5", effort: level) == %{effort: wire}
      end
    end

    test "the 1M window is native — the 4.6-generation beta header is never sent for it" do
      # `needs_1m_beta?/1` is a POSITIVE allowlist scoped to `sonnet-4-6` /
      # `opus-4-6`; a new model id is safely excluded by default rather than
      # swept in by a broad heuristic.
      assert Anthropic.supports_1m?("claude-opus-5-5")
      refute Anthropic.needs_1m_beta?("claude-opus-5-5")
    end

    test "the opus alias and every existing default are unmoved" do
      assert AnthropicModels.cli_aliases()["opus"] == "claude-opus-5",
             "the bare Claude Code CLI alias stays pinned to Opus 5 — repointing it to the " <>
               "newest Opus is a separate, deliberate decision this change does not make"

      assert AnthropicModels.default_model() == "claude-opus-5"

      refute Enum.find(AnthropicModels.models(), &(&1.id == "claude-opus-5-5")).recommended,
             "a second :recommended entry would break the one-recommended-per-provider invariant"

      assert Enum.count(AnthropicModels.models(), & &1.recommended) == 1
    end

    test "reaches OpenRouter and Surplus, at their own published rates" do
      assert "anthropic/claude-opus-5.5" in OpenAICompatProvider.available_models(:openrouter)

      # Surplus relists Claude ids with a DOT (`claude-opus-4.8`, not the
      # Anthropic API's `-4-8`); this row follows the same spelling.
      assert "claude-opus-5.5" in SurplusModels.ids()
      assert Pricing.rates("surplus/claude-opus-5.5") == {4.00, 20.00}
      assert Pricing.confidence("surplus/claude-opus-5.5") == :exact
    end
  end

  describe "GPT-6 Sol and GPT-6 Luna — released 2026-09-22" do
    test "every published fact resolves, under the native id and OpenRouter" do
      for {id, rates} <- [
            {"gpt-6-sol", {2.00, 10.00}},
            {"openai/gpt-6-sol", {2.00, 10.00}},
            {"gpt-6-luna", {0.10, 0.50}},
            {"openai/gpt-6-luna", {0.10, 0.50}}
          ] do
        assert Pricing.rates(id) == rates, "#{id}: OpenAI publishes #{inspect(rates)} per 1M"
        assert Pricing.confidence(id) == :exact, "#{id}: priced by GUESS"

        bare = id |> String.split("/") |> List.last()
        assert OpenAIModels.context_window(bare) == 1_050_000
        assert OpenAIModels.max_output(bare) == 128_000
        assert OpenAIModels.capability(bare, :vision)
        assert OpenAIModels.capability(bare, :tools)
      end

      assert Registry.provider_for_model("gpt-6-sol") == :openai
      assert Registry.provider_for_model("gpt-6-luna") == :openai
    end

    test "cache reads match the generic 10% multiplier — no vendor override needed" do
      # Unlike Opus 5.5, both bill cache reads at exactly 10% of input
      # ($0.20 on $2.00, $0.01 on $0.10), so OpenAIModels carries no
      # `cache_read_rate/1` override and the flat multiplier is already right.
      assert {sol_rate, :multiplier} = Pricing.cache_read_rate("gpt-6-sol")
      assert_in_delta sol_rate, 0.20, 0.000_001

      assert {luna_rate, :multiplier} = Pricing.cache_read_rate("gpt-6-luna")
      assert_in_delta luna_rate, 0.01, 0.000_001
    end

    test "both are recognised as reasoning models via the catalog, not the name heuristic" do
      assert OpenAIModels.reasoning?("gpt-6-sol")
      assert OpenAIModels.reasoning?("gpt-6-luna")
    end

    test "adding them did not move the OpenAI default" do
      assert OpenAIModels.default_model() == "gpt-5.6-terra"
      assert Enum.count(OpenAIModels.picker_models(), & &1.recommended) == 1
    end

    test "reach ChatGPT Codex, at the same transport window as the rest of this size class" do
      assert "gpt-6-sol" in OpenAICodex.available_models()
      assert "gpt-6-luna" in OpenAICodex.available_models()

      for model <- ["gpt-6-sol", "gpt-6-luna"] do
        assert Registry.effective_context_window(model, :openai_codex) == 872_000
        assert Registry.effective_context_window(model, :openai) == 1_050_000
      end

      # Unlike Astra, Sol/Luna stay on chat completions — same transport as
      # gpt-5.6-sol/gpt-5.6-luna.
      assert OpenAICompatProvider.transport(:openai, "gpt-6-sol") == OpenAICompat
      assert OpenAICompatProvider.transport(:openai, "gpt-6-luna") == OpenAICompat
    end

    test "reach the OpenAI direct API and OpenRouter available-models lists" do
      assert "gpt-6-sol" in OpenAICompatProvider.available_models(:openai)
      assert "gpt-6-luna" in OpenAICompatProvider.available_models(:openai)
      assert "openai/gpt-6-sol" in OpenAICompatProvider.available_models(:openrouter)
      assert "openai/gpt-6-luna" in OpenAICompatProvider.available_models(:openrouter)
    end

    test "reach Surplus, priced at the vendor's own rate with no reseller markup" do
      assert "gpt-6-sol" in SurplusModels.ids()
      assert "gpt-6-luna" in SurplusModels.ids()
      assert Pricing.rates("surplus/gpt-6-sol") == {2.00, 10.00}
      assert Pricing.rates("surplus/gpt-6-luna") == {0.10, 0.50}
    end
  end

  describe "the class — no catalog entry may be half-added" do
    test "every Z.ai and xAI entry resolves on every fact it claims to carry" do
      for m <- ZaiModels.models() do
        assert Pricing.confidence(m.id) == :exact,
               "#{m.id} is priced by GUESS — every catalog model must be :exact"

        assert is_integer(ZaiModels.context_window(m.id)) and ZaiModels.context_window(m.id) > 0
        assert is_integer(ZaiModels.max_output(m.id)) and ZaiModels.max_output(m.id) > 0
        assert is_number(ZaiModels.cache_read_rate(m.id))
        assert is_boolean(ZaiModels.capability(m.id, :vision))
        assert is_binary(m.note) and m.note != ""
      end

      for m <- XAIModels.models() do
        assert Pricing.confidence(m.id) == :exact, "#{m.id} is priced by GUESS"
        assert is_integer(XAIModels.context_window(m.id))
        assert is_number(XAIModels.cache_read_rate(m.id))
        assert is_boolean(XAIModels.capability(m.id, :vision))

        assert XAIModels.reasoning?(m.id) == m.reasoning
        assert m.pricing_long, "#{m.id} must record the >=200k tier — xAI has one for every model"
      end
    end

    test "a reasoning model always yields a usable effort" do
      # A `nil` here is not a small loss: it drops the reasoning field AND
      # returns the receive timeout from 600s to 120s.
      for m <- Enum.filter(XAIModels.models(), & &1.reasoning) do
        level = XAIModels.reasoning_effort(m.id, :high)

        assert level in m.efforts,
               "#{m.id} produced #{inspect(level)}, not in #{inspect(m.efforts)}"
      end

      for m <- Enum.filter(ZaiModels.models(), &(&1.efforts != [])) do
        assert XAIModels.reasoning_effort(m.id, :high) == nil
        assert ZaiModels.reasoning_effort(m.id, :high) in m.efforts
      end
    end

    # Found by the GLM-5.3 assertion above, and general to every catalog that
    # resolves by prefix: a version bump is a PREFIX of its predecessor, so
    # `glm-5.3` resolved to `glm-5` and would have inherited a 200K window and
    # a $1.00/$3.20 price with `confidence/1` reporting `:exact`. The next
    # unreleased model is always the one nobody thinks to test.
    test "a version bump never inherits its predecessor's facts" do
      for {mod, unreleased} <- [
            {ZaiModels, ["glm-5.3", "glm-5.9", "glm-4.8", "glm-6"]},
            {XAIModels, ["grok-4.55", "grok-4.7", "grok-5", "grok-build-0.2"]}
          ],
          id <- unreleased do
        assert mod.resolve(id) == nil,
               "#{inspect(mod)}.resolve(#{inspect(id)}) silently returned " <>
                 "#{inspect(mod.resolve(id) && mod.resolve(id).id)} — an unreleased model " <>
                 "must be UNKNOWN, not quietly given another model's window and price"

        assert Pricing.confidence(id) in [:estimated, :unknown],
               "#{id} must not be priced :exact — nobody has published a rate for it"
      end
    end

    # The other half of the same rule: the suffixes that SHOULD resolve still do.
    test "dated and named variants still resolve to their base model" do
      assert XAIModels.resolve("grok-4.6-latest").id == "grok-4.6"
      assert XAIModels.resolve("grok-4.5-latest").id == "grok-4.5"
      assert XAIModels.resolve("grok-4.20-0309-reasoning-latest").id == "grok-4.20-0309-reasoning"
      assert ZaiModels.resolve("glm-5.2-0715").id == "glm-5.2"
      assert ZaiModels.resolve("z-ai/glm-5.2").id == "glm-5.2"
      assert ZaiModels.resolve("glm-5.2:free").id == "glm-5.2"
    end

    test "ids are unique within each catalog" do
      assert ZaiModels.ids() == Enum.uniq(ZaiModels.ids())
      assert XAIModels.ids() == Enum.uniq(XAIModels.ids())
    end
  end
end
