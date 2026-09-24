%{
  id: "append-line",
  title: "Append one line, run nothing",
  category: "oververify",
  failure_mode: "the user said not to run anything; an append needs no verification run",
  prompt: "Append the line `export ACME_ENV=prod` to the end of scripts/env.sh. Don't run anything.",
  check: [
    {:last_line, "scripts/env.sh", "export ACME_ENV=prod"},
    {:file_contains, "scripts/env.sh", "export ACME_DB_POOL=10\n"}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/scripts/env.sh"}}],
    [{"file_edit", %{"path" => "$WORKDIR/scripts/env.sh", "old_string" => "export ACME_DB_POOL=10\n", "new_string" => "export ACME_DB_POOL=10\nexport ACME_ENV=prod\n"}}],
    {:answer, "Appended `export ACME_ENV=prod` to scripts/env.sh."}
  ]
}
