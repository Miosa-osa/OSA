%{
  id: "git-history",
  title: "Which commit introduced a setting?",
  category: "search",
  failure_mode: "answer from git history instead of guessing from the current tree",
  prompt: "Which commit introduced the retry_backoff_ms setting in config/settings.json? Reply with the commit subject line.",
  setup: [
    {:git_init},
    {:git_commit, "Initial import"},
    {:replace, "config/settings.json", "  \"max_retries\": 3,\n", "  \"max_retries\": 3,\n  \"retry_backoff_ms\": 250,\n"},
    {:git_commit, "Back off between webhook delivery retries"},
    {:replace, "config/settings.json", "\"log_level\": \"info\"", "\"log_level\": \"warn\""},
    {:git_commit, "Quieter default logging"}
  ],
  check: [
    {:answer_matches, "Back off between webhook delivery retries"}
  ],
  reference: [
    [{"shell_execute", %{"command" => "cd $WORKDIR && git log -S retry_backoff_ms --format=%s -- config/settings.json"}}],
    {:answer, "Back off between webhook delivery retries"}
  ]
}
