import Config

config :optimal_system_agent,
  # Default LLM provider: :ollama (local) or :anthropic (cloud) or :openai
  default_provider: :ollama,

  # Ollama settings (local LLM — no API key needed)
  ollama_url: "http://localhost:11434",
  ollama_model: "qwen3:8b",

  # Anthropic settings (set ANTHROPIC_API_KEY env var)
  anthropic_model: "anthropic-latest",

  # OpenAI-compatible settings (set OPENAI_API_KEY env var)
  openai_url: "https://api.openai.com/v1",
  openai_model: "gpt-4o",

  # Agent configuration
  max_iterations: 20,
  temperature: 0.7,
  max_tokens: 4096,

  # Signal Theory — noise filter confidence threshold
  noise_filter_threshold: 0.6,

  # Context compaction thresholds (3-tier)
  compaction_warn: 0.80,
  compaction_aggressive: 0.85,
  compaction_emergency: 0.95,

  # Proactive monitor interval (milliseconds)
  proactive_interval: 30 * 60 * 1000,

  # User config directory
  config_dir: Path.expand("~/.osa"),

  # Skills directory (SKILL.md files)
  skills_dir: Path.expand("~/.osa/skills"),

  # MCP servers config
  mcp_config_path: Path.expand("~/.osa/mcp.json"),

  # Bootstrap files directory (IDENTITY.md, SOUL.md, USER.md)
  bootstrap_dir: Path.expand("~/.osa"),

  # Data directory
  data_dir: Path.expand("~/.osa/data"),

  # Sessions directory (JSONL files)
  sessions_dir: Path.expand("~/.osa/sessions"),

  # HTTP channel (SDK API surface)
  http_port: 8089,
  require_auth: false,

  # ---------------------------------------------------------------------------
  # Sandbox — Docker container isolation for skill execution
  # ---------------------------------------------------------------------------
  # Master switch. Set OSA_SANDBOX_ENABLED=true in your environment to enable.
  # The sandbox is opt-in; all existing behaviour is preserved when disabled.
  sandbox_enabled: System.get_env("OSA_SANDBOX_ENABLED", "false") == "true",

  # Execution backend: :docker (OS-level isolation) or :beam (process-only)
  sandbox_mode: :docker,

  # Container image used for execution (build with: mix osa.sandbox.setup)
  sandbox_image: "osa-sandbox:latest",

  # Allow network access inside the container (false = --network none)
  sandbox_network: false,

  # Resource limits passed to Docker
  sandbox_max_memory: "256m",
  sandbox_max_cpu: "0.5",

  # Per-command execution timeout in milliseconds
  sandbox_timeout: 30_000,

  # Mount ~/.osa/workspace into the container at /workspace
  sandbox_workspace_mount: true,

  # Images that skills are allowed to request via the :image opt
  sandbox_allowed_images: [
    "osa-sandbox:latest",
    "python:3.12-slim",
    "node:22-slim"
  ],

  # Linux capabilities management (defaults to maximum restriction)
  sandbox_capabilities_drop: ["ALL"],
  sandbox_capabilities_add: [],

  # Security hardening flags
  sandbox_read_only_root: true,
  sandbox_no_new_privileges: true

# Database — SQLite3
config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  database: Path.expand("~/.osa/osa.db"),
  pool_size: 5,
  journal_mode: :wal

config :optimal_system_agent, ecto_repos: [OptimalSystemAgent.Store.Repo]

config :logger,
  level: :warning

import_config "#{config_env()}.exs"
