defmodule OptimalSystemAgent.Tools.Behaviour do
  @moduledoc """
  The contract every OSA tool implements.

  Maps to `src/Tool.ts:362-695` in the Claude Code reference. Optional
  callbacks have fail-closed defaults injected by
  `use OptimalSystemAgent.Tools.Behaviour`, mirroring `buildTool()` at
  `src/Tool.ts:757-792`.

  ## Two layouts coexist

  **Structured layout** (the foundation — per-tool directory):

      lib/optimal_system_agent/tools/builtins/file_read/
      ├── tool.ex          # `use OptimalSystemAgent.Tools.Behaviour`
      ├── prompt.ex        # dynamic prompt fn
      ├── handler.ex       # execute/2 + validate_input/2 + check_permissions/2
      ├── ui.ex            # render callbacks for the Rust TUI
      └── constants.ex     # exported atoms for cross-tool reference

  **Flat layout** (legacy, unmigrated — single .ex file):
  Existing tools that still implement only `name/0, description/0,
  parameters/0, execute/1, safety/0, available?/0, deferred?/0,
  concurrent?/0`. `OptimalSystemAgent.Tools.LegacyAdapter` normalizes
  them at the registry boundary so callers see a uniform surface.

  ## Required callbacks

    * `name/0`         — unique snake_case identifier
    * `description/0`  — static description (also default body of `prompt/1`)
    * `parameters/0`   — JSON Schema map
    * One of:
        * `execute/1`  — flat signature `(input)`
        * `execute/2`  — structured signature `(input, %UseContext{})`

  All other callbacks have defaults injected by `use`.
  """

  alias OptimalSystemAgent.Tools.UseContext

  @type input :: map()
  @type validation_result ::
          {:ok, input()} | {:error, message :: String.t(), code :: integer()}
  @type permission_result ::
          {:allow, updated_input :: input()}
          | {:deny, reason :: String.t()}
          | {:ask, prompt :: String.t()}
  @type interrupt_behavior :: :cancel | :block
  @type tool_output ::
          {:ok, any()}
          | {:ok, content :: any(), metadata :: map()}
          | {:error, String.t()}

  # ── Identity ─────────────────────────────────────────────────────────
  @callback name() :: String.t()
  @callback aliases() :: [String.t()]
  @callback search_hint() :: String.t()

  # ── Schema & description ─────────────────────────────────────────────
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback prompt(opts :: keyword()) :: String.t()

  # ── Loading semantics ────────────────────────────────────────────────
  @callback available?() :: boolean()
  @callback should_defer?() :: boolean()
  @callback always_load?() :: boolean()
  @callback strict?() :: boolean()

  # ── Execution semantics (per-input) ──────────────────────────────────
  @callback concurrency_safe?(input(), UseContext.t()) :: boolean()
  @callback read_only?(input(), UseContext.t()) :: boolean()
  @callback destructive?(input(), UseContext.t()) :: boolean()
  @callback open_world?(input(), UseContext.t()) :: boolean()
  @callback interrupt_behavior() :: interrupt_behavior()
  @callback max_result_size_chars() :: pos_integer() | :infinity

  # ── Two-stage permissioning ──────────────────────────────────────────
  @callback validate_input(input(), UseContext.t()) :: validation_result()
  @callback check_permissions(input(), UseContext.t()) :: permission_result()

  # ── Execution (one of execute/1 or execute/2 must exist) ─────────────
  @callback execute(input()) :: tool_output()
  @callback execute(input(), UseContext.t()) :: tool_output()

  # ── Rendering & classification ───────────────────────────────────────
  @callback render(
              stage :: :tool_use | :tool_result | :rejected | :error | :progress,
              payload :: any(),
              opts :: keyword()
            ) :: map() | nil
  @callback to_classifier_input(input()) :: String.t() | map()

  # ── Flat-layout callbacks (preserved for unmigrated tools) ───────────
  @callback safety() :: :read_only | :write_safe | :write_destructive | :terminal
  @callback deferred?() :: boolean()
  @callback concurrent?() :: boolean()

  @optional_callbacks aliases: 0,
                      search_hint: 0,
                      prompt: 1,
                      available?: 0,
                      should_defer?: 0,
                      always_load?: 0,
                      strict?: 0,
                      concurrency_safe?: 2,
                      read_only?: 2,
                      destructive?: 2,
                      open_world?: 2,
                      interrupt_behavior: 0,
                      max_result_size_chars: 0,
                      validate_input: 2,
                      check_permissions: 2,
                      execute: 1,
                      execute: 2,
                      render: 3,
                      to_classifier_input: 1,
                      safety: 0,
                      deferred?: 0,
                      concurrent?: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour OptimalSystemAgent.Tools.Behaviour

      # ── Identity defaults ──────────────────────────────────────────
      def aliases, do: []
      def search_hint, do: ""

      # ── Loading defaults ───────────────────────────────────────────
      def available?, do: true
      def should_defer?, do: false
      def always_load?, do: false
      def strict?, do: false

      # ── Execution semantics — FAIL CLOSED ──────────────────────────
      # Mirrors src/Tool.ts:757-769 buildTool defaults: assume the
      # worst (writes, destructive, not concurrent-safe) so a sloppy
      # new tool can't accidentally bypass safety.
      def concurrency_safe?(_input, _ctx), do: false
      def read_only?(_input, _ctx), do: false
      def destructive?(_input, _ctx), do: false
      def open_world?(_input, _ctx), do: false
      def interrupt_behavior, do: :block
      def max_result_size_chars, do: 30_000

      # ── Two-stage permissioning ────────────────────────────────────
      # validate fail-OPEN (just type-check the input shape).
      # check_permissions fail-OPEN-allow (defer to global rules);
      # tools override for tool-specific deny/ask logic.
      def validate_input(input, _ctx) when is_map(input), do: {:ok, input}

      def validate_input(_input, _ctx),
        do: {:error, "Input must be a map", -32_602}

      def check_permissions(input, _ctx), do: {:allow, input}

      # ── Render & classifier defaults ───────────────────────────────
      def render(_stage, _payload, _opts), do: nil
      def to_classifier_input(_input), do: ""

      # ── Dynamic prompt — default delegates to static description ───
      def prompt(_opts), do: description()

      # ── Flat-layout compatibility shims ────────────────────────────
      # safety/0 maps to read_only?/destructive? when not overridden.
      # Structured tools should NOT override safety/0; the LegacyAdapter
      # synthesizes it from read_only?/2 + destructive?/2 instead.
      def safety, do: :write_safe

      # deferred?/0 mirrors should_defer?/0 for flat-layout callers.
      def deferred?, do: should_defer?()

      # concurrent?/0 mirrors concurrency_safe?/2 with a nil input
      # for flat-layout callers that ask the module-level question.
      def concurrent?, do: false

      defoverridable aliases: 0,
                     search_hint: 0,
                     prompt: 1,
                     available?: 0,
                     should_defer?: 0,
                     always_load?: 0,
                     strict?: 0,
                     concurrency_safe?: 2,
                     read_only?: 2,
                     destructive?: 2,
                     open_world?: 2,
                     interrupt_behavior: 0,
                     max_result_size_chars: 0,
                     validate_input: 2,
                     check_permissions: 2,
                     render: 3,
                     to_classifier_input: 1,
                     safety: 0,
                     deferred?: 0,
                     concurrent?: 0
    end
  end
end
