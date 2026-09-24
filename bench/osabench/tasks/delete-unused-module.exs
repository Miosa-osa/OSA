%{
  id: "delete-unused-module",
  title: "Delete a module after checking it is unused",
  category: "edit",
  failure_mode: "one reference search, then the delete; no repeated confirmation",
  prompt: "Acme.UnusedHelper (lib/acme/unused_helper.ex) should be dead code. Confirm nothing uses it, delete the file, and keep the suite green (elixir scripts/run_tests.exs).",
  check: [
    {:file_absent, "lib/acme/unused_helper.ex"},
    {:tests_pass}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "UnusedHelper", "path" => "$WORKDIR"}}],
    [{"shell_execute", %{"command" => "rm $WORKDIR/lib/acme/unused_helper.ex"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "Nothing referenced Acme.UnusedHelper; deleted lib/acme/unused_helper.ex. Tests pass."}
  ]
}
