%{
  id: "typo-fix",
  title: "Fix a typo the user pointed at",
  category: "oververify",
  failure_mode: "a one-word fix that tempts reading the whole repo and re-checking",
  prompt: "README.md line 3 says \"recieve\"; fix the spelling.",
  check: [
    {:file_contains, "README.md", "It will receive orders"},
    {:file_lacks, "README.md", "recieve"}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/README.md"}}],
    [{"file_edit", %{"path" => "$WORKDIR/README.md", "old_string" => "recieve", "new_string" => "receive"}}],
    {:answer, "Fixed: \"receive\"."}
  ]
}
