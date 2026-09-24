%{
  id: "large-log-needle",
  title: "Answer a question from a 40k-line log",
  category: "search",
  failure_mode: "reading a huge file whole instead of searching it",
  prompt: "In data/audit.log, which order id failed with error code E4721? Reply with just the order id.",
  setup: [
    {:large_file, "data/audit.log", 40_000,
     "2026-03-01T10:00:00Z INFO order=ORD-{{n}} status=ok latency_ms=42",
     %{27_113 => "2026-03-01T10:07:31Z ERROR order=ORD-99812 code=E4721 msg=\"card declined by issuer\""}}
  ],
  check: [
    {:answer_matches, "ORD-99812"}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "E4721", "path" => "$WORKDIR/data/audit.log"}}],
    {:answer, "ORD-99812"}
  ]
}
