[
  %{
    id: "miosa",
    name: "MIOSA",
    status: "coming_soon",
    description: "Custom + trained models, run your own harness",
    group: "recommended",
    base_url: "https://optimal.miosa.ai/v1",
    default_model: "nemotron-3-miosa",
    models: :dynamic,
    env_var: "MIOSA_API_KEY",
    requires_key: true,
    signup_url: "https://miosa.ai/settings/keys",
    availability: :limited,
    badge: "Limited access — request at miosa.ai"
  },
  %{
    id: "ollama_cloud",
    name: "Ollama Cloud",
    description: "No GPU needed — recommended",
    group: "recommended",
    base_url: "https://ollama.com",
    default_model: "glm-5.2:cloud",
    models: [
      %{
        id: "kimi-k3:cloud",
        name: "Kimi K3",
        tools: true,
        note:
          "requires Ollama Pro or Max (extra credits) · 1M ctx, 2.8T MoE — vision + thinking, frontier agentic",
        ctx: 1_048_576,
        recommended: false
      },
      %{
        id: "glm-5.2:cloud",
        name: "GLM-5.2",
        tools: true,
        note: "Z.ai flagship — long-horizon agentic + coding",
        ctx: 1_000_000,
        recommended: true
      },
      # DELIBERATE post-snapshot addition, not drift. The bare GLM-5.3 flagship
      # (glm-5.3:cloud) went live on Ollama (2026-08-30, no longer a 404) and was
      # added to `Providers.OllamaCloud`, so it flows into `providers_list/0` and
      # the frozen baseline has to carry it too.
      %{
        id: "glm-5.3:cloud",
        name: "GLM-5.3",
        tools: true,
        note: "1M ctx, 753B MoE - Z.ai flagship, long-horizon agentic coding",
        ctx: 1_048_576,
        recommended: false
      },
      # DELIBERATE post-snapshot addition, not drift. The GLM-5.3 Flash line
      # shipped (2026-08-26); `glm-5.3-flash:cloud` was added to
      # `Providers.OllamaCloud` (first natively-multimodal GLM text tag), so it
      # flows into `Onboarding.providers_list/0` and the frozen baseline has to
      # carry it too or the byte-exact comparison reports an intended change.
      %{
        id: "glm-5.3-flash:cloud",
        name: "GLM-5.3 Flash",
        tools: true,
        note: "1M ctx, 320B/18B MoE - multimodal (image+video), flash-priced agentic",
        ctx: 1_048_576,
        recommended: true
      },
      # DELIBERATE post-snapshot addition, not drift. `glm-4.7:cloud` carries no
      # `context_length` in Ollama's /api/show model_info, so the probe could
      # not resolve it and it was missing from the catalog entirely — which made
      # `Loop.ContextWindow.resolve/1` return `:unknown` for a tag this project
      # ships as its configured model, and an unknown window used to mean "never
      # compact". Adding the tag to `Providers.OllamaCloud` is the fix; it flows
      # into `Onboarding.providers_list/0`, so the frozen baseline has to carry
      # it too or the byte-exact comparison reports a catalog change that was
      # intended. Everything else in this file is still the pre-refactor dump.
      %{
        id: "glm-4.7:cloud",
        name: "GLM-4.7",
        tools: true,
        note: "RETIRED on Ollama 2026-07-15 — previous-generation Z.ai flagship",
        ctx: 202_752,
        recommended: false
      },
      %{
        id: "glm-5.1:cloud",
        name: "GLM-5.1",
        tools: true,
        note: "200K ctx — same price as 5.2 for a fifth of the window",
        ctx: 202_752,
        recommended: false
      },
      %{
        id: "kimi-k2.7-code:cloud",
        name: "Kimi K2.7 Code",
        tools: true,
        note: "Moonshot coding-focused agentic",
        ctx: 262_144,
        recommended: false
      },
      %{
        id: "kimi-k2.6:cloud",
        name: "Kimi K2.6",
        tools: true,
        note: "multimodal agentic, long-horizon coding",
        ctx: 262_144,
        recommended: false
      },
      %{
        id: "minimax-m3:cloud",
        name: "MiniMax M3",
        tools: true,
        note: "512K ctx, native multimodal + agentic",
        ctx: 524_288,
        recommended: false
      },
      # DELIBERATE post-snapshot addition, not drift. The M2-series MiniMax M2.7
      # (minimax-m2.7:cloud) was added to `Providers.OllamaCloud`, so it flows
      # into `providers_list/0` and the frozen baseline has to carry it too.
      %{
        id: "minimax-m2.7:cloud",
        name: "MiniMax M2.7",
        tools: true,
        note: "192K ctx, 229B - M2-series coding + agentic",
        ctx: 196_608,
        recommended: false
      },
      %{
        id: "deepseek-v4-pro:cloud",
        name: "DeepSeek V4 Pro",
        tools: true,
        note: "512K ctx, frontier MoE, multiple reasoning modes",
        ctx: 524_288,
        recommended: false
      },
      %{
        id: "deepseek-v4-flash:cloud",
        name: "DeepSeek V4 Flash",
        tools: true,
        note: "1M ctx, 284B MoE / 13B active — fast",
        ctx: 1_048_576,
        recommended: false
      },
      %{
        id: "gpt-oss:120b-cloud",
        name: "GPT-OSS 120B",
        tools: true,
        note: "OpenAI open-weight, strong reasoning",
        ctx: 131_072,
        recommended: false
      },
      %{
        id: "qwen3.5:cloud",
        name: "Qwen 3.5",
        tools: true,
        note: "multimodal, vision + tools",
        ctx: 262_144,
        recommended: false
      },
      %{
        id: "nemotron-3-super:cloud",
        name: "Nemotron 3 Super",
        tools: true,
        note: "262K ctx, 120B MoE — efficient agentic",
        ctx: 262_144,
        recommended: false
      },
      %{
        id: "gemma4:cloud",
        name: "Gemma 4",
        tools: true,
        note: "262K ctx, frontier reasoning + vision",
        ctx: 262_144,
        recommended: false
      },
      %{
        id: "gemma4:31b-cloud",
        name: "Gemma 4 31B",
        tools: true,
        note: "262K ctx, pinned 31B tag of Gemma 4",
        ctx: 262_144,
        recommended: false
      },
      %{
        id: "gpt-oss:20b-cloud",
        name: "GPT-OSS 20B",
        tools: true,
        note: "OpenAI open-weight, fast — light utility tier",
        ctx: 131_072,
        recommended: false
      }
    ],
    recommended: true,
    env_var: "OLLAMA_API_KEY",
    key_optional: true,
    requires_key: true,
    signup_url: "https://ollama.com/account/keys"
  },
  %{
    id: "ollama_local",
    name: "Ollama Local",
    description: "Private — needs a local GPU",
    group: "bring_your_own",
    base_url: "http://localhost:11434",
    default_model: nil,
    models: :dynamic,
    env_var: nil,
    requires_key: false,
    signup_url: "https://ollama.com/download"
  },
  %{
    id: "openrouter",
    name: "OpenRouter",
    description: "One key → 200+ models",
    group: "recommended",
    base_url: "https://openrouter.ai/api/v1",
    default_model: "anthropic/claude-opus-5",
    models: [
      %{
        id: "stealth/ox-alpha",
        name: "Ox Alpha (free)",
        ctx: 1_048_576,
        tools: true,
        recommended: true,
        note: "FREE preview — 1M ctx stealth coding model, tops DeepSWE"
      },
      %{
        id: "openai/gpt-oss-20b:free",
        name: "GPT-OSS 20B (free)",
        ctx: 131_072,
        tools: true,
        note: "free — strong open coding model, ~o3-mini"
      },
      %{
        id: "anthropic/claude-sonnet-4-6",
        name: "Claude Sonnet 4.6",
        tools: true,
        note: "1M ctx — best for coding",
        ctx: 1_000_000,
        recommended: true
      },
      %{
        id: "anthropic/claude-opus-4-6",
        name: "Claude Opus 4.6",
        tools: true,
        note: "1M ctx — strongest reasoning",
        ctx: 1_000_000
      },
      %{
        id: "openai/gpt-5.4-pro",
        name: "GPT-5.4 Pro",
        tools: true,
        note: "1M ctx — latest frontier",
        ctx: 1_050_000
      },
      %{
        id: "google/gemini-2.5-pro",
        name: "Gemini 2.5 Pro",
        tools: true,
        note: "1M context",
        ctx: 1_000_000
      },
      %{
        id: "meta-llama/llama-4-maverick",
        name: "Llama 4 Maverick",
        tools: true,
        note: "400B MoE, 1M ctx",
        ctx: 1_000_000
      },
      %{
        id: "deepseek/deepseek-r1",
        name: "DeepSeek R1",
        tools: false,
        note: "reasoning only",
        ctx: 163_840
      }
    ],
    env_var: "OPENROUTER_API_KEY",
    requires_key: true,
    signup_url: "https://openrouter.ai/keys",
    allow_free_text: true
  },
  %{
    id: "anthropic",
    name: "Anthropic",
    description: "Claude direct — best for coding",
    group: "bring_your_own",
    base_url: "https://api.anthropic.com",
    default_model: "claude-opus-5",
    models: [
      %{
        id: "claude-opus-5",
        name: "Claude Opus 5",
        tools: true,
        note: "1M ctx — best agentic coding + deep reasoning. Default.",
        ctx: 1_000_000,
        recommended: true
      },
      %{
        id: "claude-sonnet-5",
        name: "Claude Sonnet 5",
        tools: true,
        note: "1M ctx — near-Opus quality at Sonnet cost, best speed/intelligence",
        ctx: 1_000_000,
        recommended: false
      },
      %{
        id: "claude-fable-5",
        name: "Claude Fable 5",
        tools: true,
        note: "1M ctx — most capable; hardest long-horizon work. Premium pricing.",
        ctx: 1_000_000,
        recommended: false
      },
      %{
        id: "claude-haiku-4-5",
        name: "Claude Haiku 4.5",
        tools: true,
        note: "200K ctx — fastest and cheapest, for simple high-volume tasks",
        ctx: 200_000,
        recommended: false
      }
    ],
    env_var: "ANTHROPIC_API_KEY",
    requires_key: true,
    signup_url: "https://console.anthropic.com/account/keys"
  },
  %{
    id: "openai",
    name: "OpenAI",
    description: "GPT direct",
    group: "bring_your_own",
    base_url: "https://api.openai.com/v1",
    default_model: "gpt-5.6-terra",
    models: [
      %{
        id: "gpt-5.6-terra",
        name: "GPT-5.6 Terra",
        tools: true,
        note: "1.05M ctx — best balance of capability and cost. Default.",
        ctx: 1_050_000,
        recommended: true
      },
      %{
        id: "gpt-5.6-sol",
        name: "GPT-5.6 Sol",
        tools: true,
        note: "1.05M ctx — most capable, for the hardest reasoning work",
        ctx: 1_050_000,
        recommended: false
      },
      %{
        id: "gpt-5.6-luna",
        name: "GPT-5.6 Luna",
        tools: true,
        note: "1.05M ctx — cheapest 5.6; high-throughput and simple tasks",
        ctx: 1_050_000,
        recommended: false
      }
    ],
    env_var: "OPENAI_API_KEY",
    requires_key: true,
    signup_url: "https://platform.openai.com/api-keys"
  },
  %{
    id: "custom",
    name: "Custom Endpoint",
    description: "Any OpenAI-compatible URL",
    group: "bring_your_own",
    base_url: nil,
    default_model: nil,
    models: :manual,
    env_var: "OPENAI_API_KEY",
    requires_key: :optional,
    signup_url: nil
  },
  %{
    id: "google",
    name: "Google Gemini",
    description: "Gemini direct — long context",
    group: "bring_your_own",
    base_url: "https://generativelanguage.googleapis.com/v1beta",
    default_model: "gemini-3.6-flash",
    models: :dynamic,
    env_var: "GOOGLE_API_KEY",
    requires_key: true,
    signup_url: "https://aistudio.google.com/apikey"
  },
  %{
    id: "xai",
    name: "xAI",
    description: "Grok models",
    group: "bring_your_own",
    base_url: "https://api.x.ai/v1",
    # Moved from grok-4.5 on 2026-08-15 when Grok 4.6 was added — same 500K
    # window, same {2.00, 6.00} price, xAI's current flagship.
    default_model: "grok-4.6",
    models: :dynamic,
    env_var: "XAI_API_KEY",
    requires_key: true,
    signup_url: "https://console.x.ai"
  },
  %{
    id: "groq",
    name: "Groq",
    description: "Fastest inference",
    group: "bring_your_own",
    base_url: "https://api.groq.com/openai/v1",
    default_model: "openai/gpt-oss-120b",
    models: :dynamic,
    env_var: "GROQ_API_KEY",
    requires_key: true,
    signup_url: "https://console.groq.com/keys"
  },
  %{
    id: "deepseek",
    name: "DeepSeek",
    description: "Strong reasoning, low cost",
    group: "bring_your_own",
    base_url: "https://api.deepseek.com/v1",
    default_model: "deepseek-v4-flash",
    models: :dynamic,
    env_var: "DEEPSEEK_API_KEY",
    requires_key: true,
    signup_url: "https://platform.deepseek.com/api_keys"
  },
  %{
    id: "mistral",
    name: "Mistral",
    description: "European models",
    group: "bring_your_own",
    base_url: "https://api.mistral.ai/v1",
    default_model: "mistral-medium-latest",
    models: :dynamic,
    env_var: "MISTRAL_API_KEY",
    requires_key: true,
    signup_url: "https://console.mistral.ai/api-keys"
  },
  %{
    id: "cohere",
    name: "Cohere",
    description: "Command models",
    group: "bring_your_own",
    base_url: "https://api.cohere.com/v2",
    default_model: "command-a-plus-05-2026",
    models: :dynamic,
    env_var: "COHERE_API_KEY",
    requires_key: true,
    signup_url: "https://dashboard.cohere.com/api-keys"
  },
  %{
    id: "cerebras",
    name: "Cerebras",
    description: "Ultra-fast inference",
    group: "more",
    base_url: "https://api.cerebras.ai/v1",
    default_model: "gpt-oss-120b",
    models: :dynamic,
    env_var: "CEREBRAS_API_KEY",
    requires_key: true,
    signup_url: "https://cloud.cerebras.ai"
  },
  %{
    id: "fireworks",
    name: "Fireworks",
    description: "Open models, serverless",
    group: "more",
    base_url: "https://api.fireworks.ai/inference/v1",
    default_model: "accounts/fireworks/models/kimi-k2p7-code",
    models: :dynamic,
    env_var: "FIREWORKS_API_KEY",
    requires_key: true,
    signup_url: "https://fireworks.ai/account/api-keys"
  },
  %{
    id: "together",
    name: "Together AI",
    description: "Open models",
    group: "more",
    base_url: "https://api.together.xyz/v1",
    default_model: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
    models: :dynamic,
    env_var: "TOGETHER_API_KEY",
    requires_key: true,
    signup_url: "https://api.together.xyz/settings/api-keys"
  },
  %{
    id: "perplexity",
    name: "Perplexity",
    description: "Search-grounded answers",
    group: "more",
    base_url: "https://api.perplexity.ai",
    default_model: "sonar-pro",
    models: :dynamic,
    env_var: "PERPLEXITY_API_KEY",
    requires_key: true,
    signup_url: "https://www.perplexity.ai/settings/api"
  },
  %{
    id: "replicate",
    name: "Replicate",
    description: "Hosted open models",
    group: "more",
    base_url: "https://api.replicate.com/v1",
    default_model: "openai/gpt-oss-120b",
    models: :dynamic,
    env_var: "REPLICATE_API_KEY",
    requires_key: true,
    signup_url: "https://replicate.com/account/api-tokens"
  },
  %{
    id: "sambanova",
    name: "SambaNova",
    description: "Fast open models",
    group: "more",
    base_url: "https://api.sambanova.ai/v1",
    default_model: "Meta-Llama-3.3-70B-Instruct",
    models: :dynamic,
    env_var: "SAMBANOVA_API_KEY",
    requires_key: true,
    signup_url: "https://cloud.sambanova.ai/apis"
  },
  %{
    id: "hyperbolic",
    name: "Hyperbolic",
    description: "Open models",
    group: "more",
    base_url: "https://api.hyperbolic.xyz/v1",
    default_model: "meta-llama/Llama-3.3-70B-Instruct",
    models: :dynamic,
    env_var: "HYPERBOLIC_API_KEY",
    requires_key: true,
    signup_url: "https://app.hyperbolic.xyz/settings"
  },
  %{
    id: "qwen",
    name: "Qwen (Alibaba)",
    description: "Qwen models",
    group: "more",
    base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    default_model: "qwen-max",
    models: :dynamic,
    env_var: "QWEN_API_KEY",
    requires_key: true,
    signup_url: "https://dashscope.console.aliyun.com"
  },
  %{
    id: "moonshot",
    name: "Moonshot (Kimi)",
    description: "Kimi models",
    group: "more",
    base_url: "https://api.moonshot.cn/v1",
    default_model: "moonshot-v1-128k",
    models: :dynamic,
    env_var: "MOONSHOT_API_KEY",
    requires_key: true,
    signup_url: "https://platform.moonshot.cn/console/api-keys"
  },
  %{
    id: "zhipu",
    name: "Zhipu (GLM)",
    description: "GLM models",
    group: "more",
    base_url: "https://open.bigmodel.cn/api/paas/v4",
    default_model: "glm-4-plus",
    models: :dynamic,
    env_var: "ZHIPU_API_KEY",
    requires_key: true,
    signup_url: "https://open.bigmodel.cn/usercenter/apikeys"
  },
  %{
    id: "volcengine",
    name: "Volcengine (Doubao)",
    description: "Doubao models",
    group: "more",
    base_url: "https://ark.cn-beijing.volces.com/api/v3",
    default_model: "doubao-pro-128k",
    models: :dynamic,
    env_var: "VOLCENGINE_API_KEY",
    requires_key: true,
    signup_url: "https://console.volcengine.com/ark"
  },
  %{
    id: "baichuan",
    name: "Baichuan",
    description: "Baichuan models",
    group: "more",
    base_url: "https://api.baichuan-ai.com/v1",
    default_model: "Baichuan4",
    models: :dynamic,
    env_var: "BAICHUAN_API_KEY",
    requires_key: true,
    signup_url: "https://platform.baichuan-ai.com"
  },
  %{
    id: "lmstudio",
    name: "LM Studio",
    description: "Local server — no key needed",
    group: "bring_your_own",
    base_url: "http://localhost:1234/v1",
    default_model: "local-model",
    models: :dynamic,
    env_var: nil,
    requires_key: false,
    signup_url: nil
  },
  %{
    id: "llamacpp",
    name: "llama.cpp",
    description: "Local server — no key needed",
    group: "bring_your_own",
    base_url: "http://localhost:8080/v1",
    default_model: "local-model",
    models: :dynamic,
    env_var: nil,
    requires_key: false,
    signup_url: nil
  }
]
