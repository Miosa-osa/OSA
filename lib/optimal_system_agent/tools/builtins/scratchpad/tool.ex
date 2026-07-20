defmodule OptimalSystemAgent.Tools.Builtins.Scratchpad.Tool do
  @moduledoc """
  Structured-layout tool: the file-based shared scratchpad.

  Per-tool directory layout — declarations only; all logic lives in siblings:

    * `Scratchpad.Constants` — exported atoms for cross-tool reference
    * `Scratchpad.Prompt`    — model-facing description
    * `Scratchpad.Handler`   — validate / check_permissions / execute
    * `Scratchpad.UI`        — render callbacks for the Rust TUI

  Backed by `OptimalSystemAgent.Scratchpad`, which resolves a real directory
  under `<config_dir>/scratchpad/<coordination_id>/` at runtime. Complements —
  does not replace — the ephemeral ETS `Team` scratchpad: this surface is
  durable, inspectable, and shared across a coordinator and its spawned workers.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Scratchpad.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["shared_scratchpad", "notes"]

  @impl true
  def search_hint, do: "shared file-based scratchpad for coordinator/worker coordination"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => Constants.valid_actions(),
          "description" =>
            "Action: write (create/overwrite an entry), append (add to an entry), " <>
              "read (read an entry), list (all entries), delete (remove an entry)."
        },
        "name" => %{
          "type" => "string",
          "description" =>
            "Entry name — a relative filename like 'findings.md'. Required for " <>
              "write/append/read/delete. Absolute paths, '~', and '..' are rejected."
        },
        "content" => %{
          "type" => "string",
          "description" => "Text content for write/append."
        },
        "team_id" => %{
          "type" => "string",
          "description" =>
            "Optional team identifier for team-scoped sharing. Omit to use the " <>
              "shared session scratchpad (workers automatically share the " <>
              "coordinator's directory)."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Available whenever agents coordinate — don't defer behind tool-search.
  def should_defer?, do: false

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  # write/append/delete mutate a shared directory — not concurrency-safe.
  def concurrency_safe?(%{"action" => "read"}, _ctx), do: true
  def concurrency_safe?(%{"action" => "list"}, _ctx), do: true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(%{"action" => action}, _ctx), do: action in ["read", "list"]
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(%{"action" => "delete"}, _ctx), do: true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

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
  def to_classifier_input(%{"action" => a, "name" => n}), do: %{action: a, name: n}
  def to_classifier_input(%{"action" => a}), do: %{action: a}
  def to_classifier_input(_), do: ""
end
