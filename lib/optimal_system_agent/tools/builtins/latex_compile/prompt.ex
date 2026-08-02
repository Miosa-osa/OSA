defmodule OptimalSystemAgent.Tools.Builtins.LatexCompile.Prompt do
  @moduledoc """
  Dynamic prompt for `latex_compile`.

  Mirrors the pattern from `ShellExecute.Prompt` — content is resolved lazily
  so future signal-aware customization can hook in via `opts`.
  """

  alias OptimalSystemAgent.Tools.Builtins.LatexCompile.Constants

  @doc """
  Render the latex_compile tool prompt.

  `opts` is reserved for future signal-aware customization.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Compiles a LaTeX document to PDF and returns a structured result.

    Give the source EITHER inline via `tex_content` (a full LaTeX document,
    `\\documentclass … \\end{document}`) OR by path via `tex_path` (an existing
    `.tex` file). Provide exactly one; `tex_content` wins if both are set.

    Engines (`engine`):
    - `tectonic` (DEFAULT, RECOMMENDED) — self-contained, fetches packages on
      demand, no system TeX install required. Prefer it.
    - `latexmk` — drives pdflatex with automatic multi-pass for cross-references.
    - `pdflatex` — run directly (this tool runs it twice for references).

    Output:
    - `output_dir` (optional) — directory for the `.tex`, `.log`, and `.pdf`.
      Defaults to a fresh timestamped directory under `#{Constants.base_output_dir()}`.
    - `jobname` (optional) — base name for the artifacts. Defaults to
      `#{Constants.default_jobname()}`.

    The result is a map:
    - `status` — `"ok"` when a PDF was produced, `"error"` otherwise.
    - `pdf_path` — absolute path to the PDF on success, `nil` on failure.
    - `log_path` — absolute path to the combined build log (always written).
    - `errors` — parsed LaTeX error lines (`! …` plus the following `l.<n>`),
      empty on success.
    - `engine`, `output_dir` — echo the resolved engine and directory.

    On a compile failure read `errors` and the `log_path`, fix the source, and
    recompile. A missing engine yields `status: "error"` with a clear message.
    """
  end
end
