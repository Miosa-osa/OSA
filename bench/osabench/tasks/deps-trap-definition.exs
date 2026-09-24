%{
  id: "deps-trap-definition",
  title: "Find a definition when deps/ and _build/ are full of lookalikes",
  category: "search",
  failure_mode: "the obvious repo-wide search walks _build/ and deps/",
  prompt: "Where is parse_header/1 defined in this project's own code (not dependencies or build output)? Reply with the file path.",
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
    {:answer_matches, "lib/acme/http/headers.ex"},
    {:answer_lacks, "deps/"}
  ],
  reference: [
    [{"file_grep", %{"pattern" => "def parse_header", "path" => "$WORKDIR/lib"}}],
    {:answer, "lib/acme/http/headers.ex"}
  ]
}
