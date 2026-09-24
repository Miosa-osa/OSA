%{
  id: "source-of-truth-port",
  title: "Config beats stale docs",
  category: "verify",
  failure_mode: "trusting the README over the config that is actually loaded",
  prompt: "What port does the dev server listen on? Reply with just the number.",
  check: [
    {:answer_matches, ~r/\b4102\b/},
    {:answer_lacks, "4000"}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "port", "path" => "$WORKDIR/config"}}],
    {:answer, "4102"}
  ]
}
