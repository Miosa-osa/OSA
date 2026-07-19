defmodule OptimalSystemAgent.Tools.Builtins.UseTool.Tool do
  @moduledoc """
  `use_tool` — meta-dispatch for virtualized MCP tools (steal-list 11g).

  When a large MCP toolset is virtualized (see `MCP.Virtualization`), the raw
  `mcp__server__tool` schemas are kept OUT of the base tool list. `tool_search`
  lets the model discover them; `use_tool` lets the model invoke them by name.
  Together they replace "inject every MCP tool into the prompt" with a two-tool
  discover-then-dispatch flow.

  Loading semantics:
    * `should_defer?/0` → `not Virtualization.active?()`. When virtualization is
      active the dispatcher is present in the base prompt; when it is inactive
      (small toolset / disabled) the dispatcher is deferred, so the small-toolset
      prompt is byte-for-byte unchanged.
    * `always_load?/0` → false — deferral is what hides it when unused.

  Execution semantics: fail-closed at the dispatcher (the *dispatched* tool
  enforces its own read-only/destructive/permission profile via
  `Registry.execute/2`).
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.UseTool.{Constants, Handler, Prompt, UI}
  alias OptimalSystemAgent.MCP.Virtualization

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["dispatch_tool", "call_tool"]

  @impl true
  def search_hint, do: "invoke a virtualized/deferred tool discovered via tool_search"

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
        "tool_name" => %{
          "type" => "string",
          "description" =>
            ~S|The fully-qualified name of a tool discovered via tool_search (e.g. "mcp__linear__create_issue"). Must not be a tool already present in the base tool list.|
        },
        "tool_input" => %{
          "type" => "object",
          "description" =>
            "Arguments for the dispatched tool, as a JSON object matching the schema returned by tool_search.",
          "additionalProperties" => true
        }
      },
      "required" => ["tool_name"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────

  # Present in the base prompt only while virtualization is active; deferred
  # otherwise so the small-toolset prompt is unchanged.
  @impl true
  def should_defer?, do: not Virtualization.active?()

  @impl true
  def always_load?, do: false

  # ── Execution semantics — fail closed; the dispatched tool sets the real
  # profile and enforces its own permissions via Registry.execute/2. ──────
  @impl true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  # Dispatched tool results (esp. MCP) can be large; match tool_search's ceiling.
  @impl true
  def max_result_size_chars, do: 100_000

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
  def to_classifier_input(%{"tool_name" => n}), do: %{tool_name: n}
  def to_classifier_input(_), do: ""
end
