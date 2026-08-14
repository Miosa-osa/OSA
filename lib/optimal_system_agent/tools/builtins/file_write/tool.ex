defmodule OptimalSystemAgent.Tools.Builtins.FileWrite.Tool do
  @moduledoc """
  Structured-layout file_write tool implementation.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `FileWrite.Constants`  — exported atoms for cross-tool reference
    * `FileWrite.Prompt`     — dynamic prompt builder (references file_read name)
    * `FileWrite.Handler`    — validate / check_permissions / execute
    * `FileWrite.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.FileWrite.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["write", "write_file"]

  @impl true
  def search_hint, do: "write or overwrite a file on the local filesystem"

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
        "path" => %{
          "type" => "string",
          "description" => "Path to write. Relative paths root at ~/.osa/workspace/."
        },
        "content" => %{
          "type" => "string",
          # "Content to write" produced small, timid calls: the model would
          # emit a stub and then patch it up over several turns. Naming the
          # completeness requirement is what makes the whole-file write happen
          # in one call (competitor-techniques.md §7.2).
          "description" =>
            "The COMPLETE final contents of the file, written out in full — " <>
              "not a fragment, a diff, or a placeholder like \"... rest unchanged\". " <>
              "Whatever is not here is gone."
        }
      },
      "required" => ["path", "content"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # file_write is in the hot path — always include it in the prompt.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Writes mutate state — never safe to run concurrently.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # file_write overwrites existing files — treat as destructive.
  def destructive?(_input, _ctx), do: true

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: 30_000

  # ── Flat-layout compatibility ──────────────────────────────────────────────────
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
  def to_classifier_input(%{"path" => p}), do: %{path: p}
  def to_classifier_input(_), do: ""
end
