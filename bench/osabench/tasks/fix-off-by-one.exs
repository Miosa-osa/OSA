%{
  id: "fix-off-by-one",
  title: "Fix an off-by-one in pagination",
  category: "fix",
  failure_mode: "localise a failure from the test output, fix, re-run once",
  prompt: "The paginator tests fail. Find and fix the bug in lib/, then confirm the suite passes (elixir scripts/run_tests.exs).",
  setup: [
    {:replace, "lib/acme/paginator.ex", "(page_number - 1) * per_page", "page_number * per_page"}
  ],
  check: [
    {:tests_pass},
    {:file_unchanged, "test/paginator_test.exs"}
  ],
  reference: [
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}},
     {"file_read", %{"path" => "$WORKDIR/lib/acme/paginator.ex"}}],
    [{"file_edit", %{"path" => "$WORKDIR/lib/acme/paginator.ex",
                     "old_string" => "page_number * per_page",
                     "new_string" => "(page_number - 1) * per_page"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "Pages are 1-based; the offset is now (page_number - 1) * per_page. Tests pass."}
  ]
}
