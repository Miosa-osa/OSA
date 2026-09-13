defmodule OptimalSystemAgent.Tools.Builtins.PushNotification.Tool do
  @moduledoc """
  Send an OS-level push notification to the user's desktop.

  macOS: `osascript -e 'display notification ...'`
  Linux: `notify-send`
  Other: degrades to Logger.info (no crash)

  Use this for out-of-band signals the user should see even if they have
  stepped away from the terminal. For in-session replies, use `send_message`.

  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.PushNotification.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["notify", "alert"]

  @impl true
  def search_hint, do: "send an OS-level desktop push notification"

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{
          "type" => "string",
          "description" =>
            "Short headline shown in the notification banner (max #{Constants.max_title_chars()} chars)"
        },
        "body" => %{
          "type" => "string",
          "description" =>
            "Detail text shown below the title (max #{Constants.max_body_chars()} chars)"
        },
        "urgency" => %{
          "type" => "string",
          "enum" => Constants.valid_urgency(),
          "description" =>
            "Urgency level: #{Enum.join(Constants.valid_urgency(), " | ")}. " <>
              "Default: #{Constants.default_urgency()}. " <>
              "critical requires non-strict permission mode."
        }
      },
      "required" => ["title", "body"]
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

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  # Touches the OS notification subsystem — open world
  @impl true
  def open_world?(_input, _ctx), do: true

  @impl true
  def max_result_size_chars, do: 1_000

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
  def to_classifier_input(%{"title" => t, "body" => b} = input) do
    %{title: t, body: b, urgency: Map.get(input, "urgency", Constants.default_urgency())}
  end

  def to_classifier_input(_), do: ""
end
