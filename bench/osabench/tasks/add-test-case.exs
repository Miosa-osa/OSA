%{
  id: "add-test-case",
  title: "Add a missing test case",
  category: "edit",
  failure_mode: "a small additive edit plus one confirming run",
  prompt: "Add a test to test/slug_test.exs asserting that Acme.Slug.slugify(\"\") returns \"\". Make sure the suite passes (elixir scripts/run_tests.exs).",
  check: [
    {:file_contains, "test/slug_test.exs", ~r/slugify\(""\)\s*==\s*""/},
    {:tests_pass}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/test/slug_test.exs"}}],
    [{"file_edit", %{"path" => "$WORKDIR/test/slug_test.exs",
                     "old_string" => "    assert Acme.Slug.slugify(\"  Big Sale!! \") == \"big-sale\"\n  end\n",
                     "new_string" => "    assert Acme.Slug.slugify(\"  Big Sale!! \") == \"big-sale\"\n  end\n\n  test \"slugify of an empty string is empty\" do\n    assert Acme.Slug.slugify(\"\") == \"\"\n  end\n"}}],
    [{"shell_execute", %{"command" => "cd $WORKDIR && elixir scripts/run_tests.exs"}}],
    {:answer, "Added the empty-string case; the suite passes."}
  ]
}
