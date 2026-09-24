%{
  id: "settings-one-line",
  title: "One-line settings change",
  category: "edit",
  failure_mode: "a trivial edit that should cost one read and one edit",
  prompt: "Set max_retries to 5 in config/settings.json.",
  check: [
    {:json_equals, "config/settings.json", ["max_retries"], 5},
    {:json_unchanged_except, "config/settings.json", [["max_retries"]]}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/config/settings.json"}}],
    [{"file_edit", %{"path" => "$WORKDIR/config/settings.json",
                     "old_string" => "\"max_retries\": 3",
                     "new_string" => "\"max_retries\": 5"}}],
    {:answer, "max_retries is now 5."}
  ]
}
