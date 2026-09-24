%{
  id: "dead-function",
  title: "Find the unused public function",
  category: "search",
  failure_mode: "one search per candidate, not one read per file in the repo",
  prompt: "Which public function in lib/acme/legacy.ex is never called anywhere in lib/ or test/? Reply as name/arity.",
  check: [
    {:answer_matches, "old_format/1"},
    {:answer_lacks, "new_format/1"}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/lib/acme/legacy.ex"}}],
    [{"file_grep", %{"pattern" => "old_format|new_format", "path" => "$WORKDIR", "output_mode" => "content"}}],
    {:answer, "old_format/1"}
  ]
}
