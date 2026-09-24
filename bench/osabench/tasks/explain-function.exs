%{
  id: "explain-function",
  title: "Answer a question about behaviour from the code",
  category: "search",
  failure_mode: "reading the one relevant function instead of the whole codebase",
  prompt: "What does Acme.Billing.format_cents(1205) return? Reply with just the value.",
  check: [
    {:answer_matches, "12.05"}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/lib/acme/billing.ex"}}],
    {:answer, "\"12.05\""}
  ]
}
