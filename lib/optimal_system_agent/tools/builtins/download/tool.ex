defmodule OptimalSystemAgent.Tools.Builtins.Download.Tool do
  @moduledoc """
  Structured-layout tool implementation for `download`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `Download.Constants`  — exported atoms for cross-tool reference
    * `Download.Prompt`     — dynamic prompt builder
    * `Download.Handler`    — validate / check_permissions / execute
    * `Download.UI`         — render callbacks for the Rust TUI

  ## Execution semantics
  `should_defer? true` — network I/O is unbounded; defer to avoid blocking streaming.
  `open_world? true`   — reaches external hosts by design.
  `read_only? false`   — writes to disk.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Download.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["fetch_file", "wget"]

  @impl true
  def search_hint, do: "download a file from a URL to the local filesystem"

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
        "url" => %{
          "type" => "string",
          "description" => "URL to download from (must be https://)"
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Local path to save the file to. Relative paths are rooted at ~/.osa/workspace/"
        }
      },
      "required" => ["url", "path"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Network download can be long; defer to avoid blocking streaming response.
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Multiple downloads to different paths are safe to run in parallel.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  # Writes to disk — not read-only.
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  # Makes requests to external hosts.
  def open_world?(_input, _ctx), do: true

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
  def to_classifier_input(%{"url" => url, "path" => path}), do: %{url: url, path: path}
  def to_classifier_input(_), do: ""
end
