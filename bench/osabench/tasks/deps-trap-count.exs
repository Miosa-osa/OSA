%{
  id: "deps-trap-count",
  title: "Count call sites without counting vendored copies",
  category: "search",
  failure_mode: "an unscoped count that includes deps/ and _build/",
  prompt: "How many calls to Acme.Metrics.emit/2 are there in lib/ (not counting its definition)? Reply with just the number.",
  setup: [

    {:noise, "deps", 1_500, "pkg_{{n}}/lib/pkg_{{n}}/headers.ex", """
    defmodule Pkg{{n}}.Headers do
      # vendored copy {{n}}
      def parse_header(line), do: Acme.Metrics.emit("pkg{{n}}", String.length(line))
      def other_{{n}}(x), do: x
    end
    """},
    {:noise, "_build/dev/lib", 1_500, "pkg_{{n}}/src/headers_{{n}}.ex", """
    defmodule Pkg{{n}}.Built do
      def parse_header(line), do: Acme.Metrics.emit("built{{n}}", line)
    end
    """}

  ],
  check: [
    {:answer_matches, ~r/^\D*\b4\b\D*$/}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "Acme\\.Metrics\\.emit\\(", "path" => "$WORKDIR/lib"}}],
    {:answer, "4"}
  ]
}
