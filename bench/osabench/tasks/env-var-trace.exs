%{
  id: "env-var-trace",
  title: "Which environment variable really sets the pool size?",
  category: "verify",
  failure_mode: "stale docs name a variable the code no longer reads",
  prompt: "Which environment variable sets the database pool size at runtime? Reply with just the variable name.",
  check: [
    {:answer_matches, "ACME_DB_POOL"},
    {:answer_lacks, "POOL_SIZE"}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "pool_size", "path" => "$WORKDIR/config"}}],
    {:answer, "ACME_DB_POOL"}
  ]
}
