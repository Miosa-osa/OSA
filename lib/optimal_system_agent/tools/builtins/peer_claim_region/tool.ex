defmodule OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Tool do
  @moduledoc """
  Structured-layout entry point for `peer_claim_region`.

  Per-tool directory layout — declarations only; logic lives in sibling modules:
    * `PeerClaimRegion.Constants` — exported atoms for cross-tool reference
    * `PeerClaimRegion.Prompt`    — dynamic prompt builder
    * `PeerClaimRegion.Handler`   — validate / check_permissions / execute
    * `PeerClaimRegion.UI`        — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def search_hint, do: "claim an exclusive line range in a file before editing"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action", "file_path"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => Constants.actions(),
          "description" =>
            "claim: lock a region, release: free it, list: see all claims, touch: reset expiry timer"
        },
        "file_path" => %{
          "type" => "string",
          "description" => "Absolute path to the file."
        },
        "start_line" => %{
          "type" => "integer",
          "description" => "First line of the region (1-indexed, inclusive). Required for claim."
        },
        "end_line" => %{
          "type" => "integer",
          "description" => "Last line of the region (inclusive). Required for claim."
        },
        "region_id" => %{
          "type" => "string",
          "description" => "Region ID returned by a prior claim. Required for release/touch."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  # ── Execution semantics ───────────────────────────────────────────────
  # Claims must serialize — concurrent claims on overlapping regions are
  # mediated by the RegionLock ETS table, so we report not safe here to
  # force the tool executor to serialize invocations.
  @impl true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

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
  def to_classifier_input(%{"action" => a, "file_path" => fp} = input),
    do: %{action: a, file_path: fp, region_id: input["region_id"]}

  def to_classifier_input(_), do: ""
end
