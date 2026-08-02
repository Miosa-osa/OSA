defmodule OptimalSystemAgent.Tools.Builtins.LatexCompile.Constants do
  @moduledoc """
  Exported constants for `latex_compile`. Mirrors the pattern established by
  `ShellExecute.Constants` — other tools' prompts can reference `tool_name/0`
  so a rename propagates automatically.
  """

  @tool_name "latex_compile"
  def tool_name, do: @tool_name

  # LaTeX runs (especially first-run package downloads under tectonic) can be
  # slow. A generous foreground window; the OS process is killed on expiry.
  @default_timeout_ms 120_000
  def default_timeout_ms, do: @default_timeout_ms

  @default_engine "tectonic"
  def default_engine, do: @default_engine

  @default_jobname "document"
  def default_jobname, do: @default_jobname

  # Engines the tool knows how to drive.
  @engines ~w(tectonic latexmk pdflatex)
  def engines, do: @engines

  # Where compiled documents land when the caller does not pass `output_dir`.
  @base_output_dir "~/.osa/latex"
  def base_output_dir, do: @base_output_dir

  # Fallback directory searched (in addition to $PATH) when resolving an engine
  # binary — the LaTeX toolchain on this host is installed here.
  @local_bin_dir "~/.local/bin"
  def local_bin_dir, do: @local_bin_dir

  # Cap on the number of parsed error lines returned so a runaway log cannot
  # flood the result map.
  @max_errors 50
  def max_errors, do: @max_errors
end
