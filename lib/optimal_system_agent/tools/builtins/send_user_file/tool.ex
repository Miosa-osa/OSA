defmodule OptimalSystemAgent.Tools.Builtins.SendUserFile.Tool do
  @moduledoc """
  Send a file to the user by emitting an event on the Events.Bus.

  The frontend subscribes to `:system_event` events with subtype
  "send_user_file" and presents the file as a download link, drag-drop
  target, or mobile attachment.

  For small previewable text files (< 512KB) the content is also included
  inline in the event payload so the frontend can render a preview without
  a second round-trip.

  This tool reads the file (read_only? false because it emits a user-side
  event) but does NOT copy or move the file.

  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.SendUserFile.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["deliver_file", "share_file"]

  @impl true
  def search_hint, do: "send a file to the user via the frontend event bus"

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
          "description" => "Absolute path to the file to send (must exist and be readable)"
        },
        "label" => %{
          "type" => "string",
          "description" => "Optional display name shown to the user (defaults to file basename)"
        },
        "description" => %{
          "type" => "string",
          "description" => "Optional one-line description of what the file contains"
        }
      },
      "required" => ["path"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  # Reads the file but emits a user-side event — not purely read_only
  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def interrupt_behavior, do: :block

  @impl true
  def max_result_size_chars, do: 2_000

  # ── Safety ────────────────────────────────────────────────────────────
  @impl true
  def safety, do: :write_safe

  # ── Pipeline ──────────────────────────────────────────────────────────
  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  @impl true
  def to_classifier_input(%{"path" => path} = input) do
    %{
      path: path,
      label: Map.get(input, "label", Path.basename(path)),
      description: Map.get(input, "description", "")
    }
  end

  def to_classifier_input(_), do: ""
end
