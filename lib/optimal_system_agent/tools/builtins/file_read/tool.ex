defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Tool do
  @moduledoc """
  Reference structured-layout tool implementation.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `FileRead.Constants`  — exported atoms for cross-tool reference
    * `FileRead.Prompt`     — dynamic prompt builder
    * `FileRead.Handler`    — validate / check_permissions / execute
    * `FileRead.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.FileRead.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["read", "read_file"]

  @impl true
  def search_hint, do: "read file contents from local filesystem"

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
          "description" => "Absolute path to the file to read"
        },
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (1-based). Optional."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to read. Optional."
        }
      },
      "required" => ["path"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # file_read must always be in the prompt — the model is told
  # "ALWAYS read before editing" so it can't be deferred.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  # Set to :infinity because file_read self-bounds via offset/limit. Auto-
  # persisting a Read result would create a circular Read→file→Read loop.
  def max_result_size_chars, do: :infinity

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :read_only

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
