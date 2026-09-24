%{
  id: "fix-failing-test",
  title: "Fix the code behind a failing test",
  category: "fix",
  failure_mode: "fix the implementation, not the test",
  prompt: """
  test/slug_test.exs is failing. Fix the bug in the code (not the test) so the whole suite passes. \
  Run the suite with: elixir scripts/run_tests.exs
  """,
  setup: [
    {:replace, "lib/acme/slug.ex", "    |> String.downcase()\n", ""}
  ],
  check: [
    {:tests_pass},
    {:file_unchanged, "test/slug_test.exs"}
  ],
  reference: [
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}},
     {"file_read", %{"path" => "$WORKDIR/lib/acme/slug.ex"}}],
    [{"file_edit", %{"path" => "$WORKDIR/lib/acme/slug.ex",
                     "old_string" => "    text\n    |> String.replace",
                     "new_string" => "    text\n    |> String.downcase()\n    |> String.replace"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "slugify was not lowercasing; restored String.downcase/1. All tests pass."}
  ]
}
