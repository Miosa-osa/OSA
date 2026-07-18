defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Tool do
  @moduledoc """
  Structured-layout entry point for `computer_use`.

  Declarations only — all logic lives in sibling modules:

    * `ComputerUse.Constants` — exported atoms and limits
    * `ComputerUse.Prompt`    — dynamic prompt covering all actions
    * `ComputerUse.Handler`   — validate / check_permissions / execute
    * `ComputerUse.UI`        — render callbacks for the Rust TUI

  The existing `computer_use/` subdirectory (adapters, accessibility,
  executor, keyframe, planner, server) is untouched — Handler delegates
  to Server and Adapter exactly as the original flat module did.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.{Constants, Handler, Prompt, UI}

  # ── Identity ───────────────────────────────────────────────────────────

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["computer", "desktop_control"]

  @impl true
  def search_hint, do: "control the desktop: screenshot, click, type, scroll, key press"

  # ── Schema & description ───────────────────────────────────────────────

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "description" => "The action to perform",
          "enum" => Constants.valid_actions() |> Enum.map(&to_string/1)
        },
        "x" => %{"type" => "integer", "description" => "X coordinate"},
        "y" => %{"type" => "integer", "description" => "Y coordinate"},
        "text" => %{"type" => "string", "description" => "Text to type or key combo"},
        "target" => %{
          "type" => "string",
          "description" => "Element ref from accessibility tree (e.g. \"e3\")"
        },
        "direction" => %{
          "type" => "string",
          "description" => "Scroll direction: up, down, left, right"
        },
        "region" => %{
          "type" => "object",
          "description" => "Screen region for screenshot or drag target",
          "properties" => %{
            "x" => %{"type" => "integer"},
            "y" => %{"type" => "integer"},
            "width" => %{"type" => "integer"},
            "height" => %{"type" => "integer"}
          }
        },
        "window" => %{
          "type" => "string",
          "description" => "Window name/title to focus before executing the action"
        },
        "window_id" => %{
          "type" => "string",
          "description" => "Window ID for focus_window"
        },
        "app" => %{
          "type" => "string",
          "description" => "Application name or command for launch"
        },
        "seconds" => %{
          "type" => "number",
          "description" => "Seconds to wait for wait action"
        },
        "amount" => %{
          "type" => "integer",
          "description" => "Scroll amount (number of wheel steps, default 3)"
        },
        "duration" => %{
          "type" => "number",
          "description" => "Seconds to hold a key for hold_key (0-30)"
        },
        "width" => %{
          "type" => "integer",
          "description" => "Window width for resize_window"
        },
        "height" => %{
          "type" => "integer",
          "description" => "Window height for resize_window"
        },
        "target_x" => %{
          "type" => "integer",
          "description" => "Target X coordinate for drag"
        },
        "target_y" => %{
          "type" => "integer",
          "description" => "Target Y coordinate for drag"
        },
        "surface" => %{
          "type" => "string",
          "description" => "Surface to observe for snapshot/list_surfaces"
        },
        "root" => %{
          "type" => "string",
          "description" => "Element ref root for a scoped snapshot"
        },
        "max_depth" => %{
          "type" => "integer",
          "description" => "Maximum accessibility tree depth for snapshot"
        },
        "interactive_only" => %{
          "type" => "boolean",
          "description" => "Only return interactive elements in snapshot"
        },
        "compact" => %{
          "type" => "boolean",
          "description" => "Return compact snapshot output"
        }
      },
      "required" => ["action"]
    }
  end

  # ── Loading semantics ──────────────────────────────────────────────────

  @impl true
  # Not deferred — once available, the model must be able to call it immediately.
  def should_defer?, do: false

  @impl true
  # Only loaded when computer use is enabled — the model uses ToolSearch to
  # discover it at runtime rather than having it pre-loaded in every prompt.
  def always_load?, do: false

  @impl true
  def available? do
    Application.get_env(:optimal_system_agent, :computer_use_enabled) === true
  end

  # ── Execution semantics ────────────────────────────────────────────────

  @impl true
  # UI events are inherently sequential — the OS serializes desktop input.
  # Concurrent computer_use calls would produce garbled results.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  # Only screenshot is read-only; all other actions mutate desktop state.
  def read_only?(%{"action" => "screenshot"}, _ctx), do: true
  def read_only?(_input, _ctx), do: false

  @impl true
  # Click/type/key/scroll interactions are reversible at the OS level
  # (Ctrl+Z, close window, etc.), so we classify as non-destructive.
  def destructive?(_input, _ctx), do: false

  @impl true
  # Computer use touches the live OS UI — it is inherently open-world.
  def open_world?(_input, _ctx), do: true

  @impl true
  # On interrupt: cancel the pending action. Blocking would stall the agent
  # loop while a human has seized the keyboard/mouse.
  def interrupt_behavior, do: :cancel

  # ── Flat-layout compatibility ──────────────────────────────────────────

  @impl true
  # Maps to the original flat-layout `:write_destructive` tier — computer use
  # can mutate any application on the desktop, but interactions are reversible
  # (clicks, types, keyframes) rather than terminal-equivalent shell access.
  def safety, do: :write_destructive

  # ── Two-stage permissioning ────────────────────────────────────────────

  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  # ── Execution ──────────────────────────────────────────────────────────

  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Rendering ─────────────────────────────────────────────────────────

  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ──────────────────────────────────────────────────

  @impl true
  def to_classifier_input(%{"action" => a} = input) do
    %{action: a, target: input["target"], x: input["x"], y: input["y"]}
  end

  def to_classifier_input(_), do: ""
end
