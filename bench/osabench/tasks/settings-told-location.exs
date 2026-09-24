%{
  id: "settings-told-location",
  title: "Edit a setting whose location the user already gave",
  category: "oververify",
  failure_mode: "re-verifying a fact the user already stated instead of acting on it",
  prompt: """
  The log level lives in config/settings.json under "log_level" (currently "info"). Change it to \
  "debug". No need to look anywhere else.
  """,
  check: [
    {:json_equals, "config/settings.json", ["log_level"], "debug"},
    {:json_unchanged_except, "config/settings.json", [["log_level"]]}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/config/settings.json"}}],
    [{"file_edit", %{"path" => "$WORKDIR/config/settings.json",
                     "old_string" => "\"log_level\": \"info\"",
                     "new_string" => "\"log_level\": \"debug\""}}],
    {:answer, "log_level is now \"debug\"."}
  ]
}
