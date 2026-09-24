%{
  id: "stop-when-answered",
  title: "A yes/no question that needs one look",
  category: "oververify",
  failure_mode: "keeps exploring after the question is answered",
  prompt: "Is there a CHANGELOG.md at the repository root? Answer yes or no.",
  check: [
    {:answer_matches, ~r/\bno\b/i},
    {:answer_lacks, ~r/\byes\b/i}
  ],
  reference: [
    [{"dir_list", %{"path" => "$WORKDIR"}}],
    {:answer, "No."}
  ]
}
