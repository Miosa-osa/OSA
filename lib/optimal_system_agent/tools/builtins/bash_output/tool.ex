defmodule OptimalSystemAgent.Tools.Builtins.BashOutput.Tool do
  @moduledoc """
  Structured-layout entry point for `bash_output`.

  Polls (or kills) a background shell command started via `shell_execute` with
  `run_in_background: true`. Interface over the background-shell mechanism in
  `OptimalSystemAgent.Shell.BackgroundManager`.

  Per-tool directory layout — declarations only; logic lives in the siblings:

    * `BashOutput.Constants` — exported atoms for cross-tool reference
    * `BashOutput.Prompt`    — dynamic prompt with `safe_ref` cross-tool links
    * `BashOutput.Handler`   — validate / check_permissions / execute
    * `BashOutput.UI`        — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.BashOutput.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["background_output", "task_output_bg"]

  @impl true
  def search_hint, do: "poll stdout/stderr and status of a background shell command; kill it"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["background_id"],
      "properties" => %{
        "background_id" => %{
          "type" => "string",
          "description" => "Id returned by shell_execute for a background command"
        },
        "kill" => %{
          "type" => "boolean",
          "description" => "Terminate the command and return final output. Default false."
        },
        "wait_ms" => %{
          "type" => "integer",
          "description" =>
            "Block for up to this many milliseconds waiting for the command to reach a " <>
              "terminal status (done/failed/killed), then return its final output. " <>
              "0 (default) returns the current snapshot immediately. Use this instead of " <>
              "polling in a loop or sleeping. Capped at 1800000 (30 min)."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Reads (kill=false) are a Registry lookup + snapshot — concurrency-safe.
  # kill=true mutates process state; conservatively not concurrency-safe.
  def concurrency_safe?(input, _ctx), do: not kill?(input)

  @impl true
  def read_only?(input, _ctx), do: not kill?(input)

  @impl true
  def destructive?(input, _ctx), do: kill?(input)

  @impl true
  def open_world?(_input, _ctx), do: false

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
  def to_classifier_input(%{"background_id" => id} = input),
    do: %{background_id: id, kill: kill?(input), wait_ms: Map.get(input, "wait_ms")}

  def to_classifier_input(_), do: ""

  # ── Private ───────────────────────────────────────────────────────────
  defp kill?(%{"kill" => true}), do: true
  defp kill?(%{"kill" => "true"}), do: true
  defp kill?(_), do: false
end
