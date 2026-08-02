defmodule OptimalSystemAgent.Tools.Builtins.LatexCompile.Tool do
  @moduledoc """
  `latex_compile` — compile a LaTeX document to PDF and return a structured
  result (status / pdf_path / log_path / parsed errors).

  Structured-layout tool: identity, schema, and semantics live here; the actual
  validation and compilation logic is delegated to `Handler`, the prompt text to
  `Prompt`, and TUI render maps to `UI` — mirroring the `ShellExecute` layout.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.LatexCompile.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["compile_latex", "latex_build", "tex_compile"]

  @impl true
  def search_hint, do: "compile LaTeX to PDF: tectonic, latexmk, pdflatex"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "tex_content" => %{
          "type" => "string",
          "description" =>
            "Full LaTeX source (\\documentclass … \\end{document}). Provide this " <>
              "OR tex_path. Takes precedence if both are given."
        },
        "tex_path" => %{
          "type" => "string",
          "description" =>
            "Path to an existing .tex file to compile. Provide this OR tex_content."
        },
        "output_dir" => %{
          "type" => "string",
          "description" =>
            "Directory for the .tex, .log, and .pdf artifacts. Defaults to a fresh " <>
              "timestamped directory under #{Constants.base_output_dir()}."
        },
        "engine" => %{
          "type" => "string",
          "enum" => Constants.engines(),
          "description" =>
            "LaTeX engine. Defaults to #{Constants.default_engine()} " <>
              "(self-contained, no system TeX install required)."
        },
        "jobname" => %{
          "type" => "string",
          "description" =>
            "Base name for the artifacts. Defaults to #{Constants.default_jobname()}."
        }
      },
      "required" => []
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Writes source/log/pdf files under a scratch dir — not read-only.
  def read_only?(_input, _ctx), do: false

  @impl true
  # Only ever writes fresh artifacts under an output dir; overwrites nothing
  # the user depends on.
  def destructive?(_input, _ctx), do: false

  @impl true
  # Each compile targets its own (default: fresh) output dir, so concurrent
  # invocations don't collide. When callers pin the same output_dir they
  # serialize themselves; the default keeps runs independent.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  # No network side effects beyond tectonic's package fetch; not open-world in
  # the shell sense.
  def open_world?(_input, _ctx), do: false

  @impl true
  # A slow compile should be cancelable rather than blocking the loop.
  def interrupt_behavior, do: :cancel

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :write_safe

  # ── Two-stage permissioning ───────────────────────────────────────────
  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  # ── Execution ─────────────────────────────────────────────────────────
  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Rendering ─────────────────────────────────────────────────────────
  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ──────────────────────────────────────────────────
  @impl true
  def to_classifier_input(input) when is_map(input) do
    %{
      engine: input["engine"] || Constants.default_engine(),
      jobname: input["jobname"],
      tex_path: input["tex_path"]
    }
  end

  def to_classifier_input(_), do: ""
end
