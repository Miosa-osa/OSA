%{
  id: "json-nested-flag",
  title: "Flip a nested JSON flag",
  category: "edit",
  failure_mode: "editing the right one of several identically named keys",
  prompt: "Enable the beta feature: set features.beta.enabled to true in config/features.json. Leave everything else as it is.",
  check: [
    {:json_equals, "config/features.json", ["features", "beta", "enabled"], true},
    {:json_unchanged_except, "config/features.json", [["features", "beta", "enabled"]]}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/config/features.json"}}],
    [{"file_edit", %{"path" => "$WORKDIR/config/features.json",
                     "old_string" => "\"enabled\": false",
                     "new_string" => "\"enabled\": true"}}],
    {:answer, "features.beta.enabled is now true."}
  ]
}
