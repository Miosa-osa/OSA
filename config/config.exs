import Config

config :optimal_system_agent,
  # Default LLM provider: :ollama (local) or :anthropic (cloud) or :openai
  default_provider: :ollama,

  # Ollama settings (local LLM — no API key needed)
  ollama_url: "http://localhost:11434",
  ollama_model: "llama3.2:latest",

  # Anthropic settings (set ANTHROPIC_API_KEY env var)
  anthropic_model: "claude-opus-4-6",

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
  sessions_dir: Path.expand("~/.osa/sessions")

# Database — SQLite3
config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  database: Path.expand("~/.osa/osa.db"),
  pool_size: 5,
  journal_mode: :wal

config :optimal_system_agent, ecto_repos: [OptimalSystemAgent.Store.Repo]

config :logger,
  level: :info

import_config "#{config_env()}.exs"
