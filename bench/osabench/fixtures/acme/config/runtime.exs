import Config

config :acme, Acme.Repo,
  pool_size: String.to_integer(System.get_env("ACME_DB_POOL") || "10"),
  timeout: 15_000
