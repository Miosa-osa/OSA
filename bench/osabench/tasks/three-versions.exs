%{
  id: "three-versions",
  title: "Three independent reads",
  category: "parallel",
  failure_mode: "independent reads that should batch into one round-trip",
  prompt: """
  Report the version declared in mix.exs, in assets/package.json and in VERSION. Reply exactly \
  as: mix=<v> package=<v> file=<v>
  """,
  check: [
    {:answer_matches, ~r/mix=2\.3\.1\s+package=1\.8\.4\s+file=2\.3\.1/}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/mix.exs"}},
     {"file_read", %{"path" => "$WORKDIR/assets/package.json"}},
     {"file_read", %{"path" => "$WORKDIR/VERSION"}}],
    {:answer, "mix=2.3.1 package=1.8.4 file=2.3.1"}
  ]
}
