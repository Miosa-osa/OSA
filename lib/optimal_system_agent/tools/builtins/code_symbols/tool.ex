defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool do
  @moduledoc """
  Structured-layout tool implementation for `code_symbols`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `CodeSymbols.Constants`  — exported atoms for cross-tool reference
    * `CodeSymbols.Prompt`     — dynamic prompt builder
    * `CodeSymbols.Handler`    — validate / check_permissions / execute
    * `CodeSymbols.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.CodeSymbols.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["symbols", "list_symbols", "find_definition", "goto_definition"]

  @impl true
  def search_hint,
    do:
      "find where a function or class is defined in a file and read just that " <>
        "definition; outline all symbols in a source file"

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
          "description" => "Path to the source file to analyze"
        },
        "name" => %{
          "type" => "string",
          "description" =>
            "Return the SOURCE of the symbol with this exact name, and nothing else. " <>
              "Omit to get the outline instead."
        },
        "type" => %{
          "type" => "string",
          "description" =>
            "Filter by symbol type: \"function\", \"class\", \"module\". Omit for all symbols."
        }
      },
      "required" => ["path"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  #
  # ALWAYS LOADED, reversing the deferral this file previously argued for. The
  # two settings below are deliberately consistent — `should_defer?: false` puts
  # the name in the native `tools` array (`Registry.list_active/0`, the only
  # thing that makes a tool callable under a native-tool provider), and
  # `always_load?: true` matches it on the prose side (`PromptAssembler`). It
  # was the DISAGREEMENT between them that produced the earlier defect: billed
  # on every request, callable on none.
  #
  # ## Why the deferral argument no longer holds
  #
  # The old comment's evidence was "invoked zero times". That was true and it
  # was not evidence about demand, because for most of that window the tool was
  # not callable and, when it was, it answered the wrong question — it returned
  # an outline, so it could not end a lookup. Zero calls to a tool nothing could
  # call is not a measurement of whether the capability is wanted.
  #
  # What IS measured is the behaviour the tool now replaces. Across 118
  # SWE-bench / SWE-bench-Pro transcripts: 862 `file_grep` calls, of which 312
  # are immediately followed by a `file_read` — locate a definition, then read a
  # guessed window around it. That is 2.6 such pairs per task. Answering one of
  # those pairs with `code_symbols {path, name}` costs 517 bytes against 1,381
  # for the grep-then-read route, and one round trip against two.
  #
  # ## The prefix arithmetic
  #
  # Against that: this tool's schema is ~600 bytes at the FRONT of the cached
  # prefix, on every request of every session. The comparison is not 600 against
  # 860, because the two are not paid at the same rate. The prefix is a cache
  # hit ~92.8% of the time, so its marginal cost is roughly a tenth of face
  # value; the saved result bytes and the saved round trip are paid at full
  # price, every time. One call per task clears it several times over, and the
  # corpus shows 2.6 opportunities per task.
  #
  # ## What this costs elsewhere
  #
  # A one-time change to the assembled prefix, which is fine — caching depends
  # on the prefix being byte-identical across turns WITHIN a session, not across
  # deploys. Nothing here varies per turn.
  #
  # Reopen this if adoption is measured and stays at zero with the tool loaded
  # and the routing text in place. At that point the schema is genuinely fat and
  # the argument reverses on evidence rather than on the absence of it.
  @impl true
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Read-only regex scan — safe to run concurrently.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

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
  def to_classifier_input(%{"path" => p}), do: %{path: p}
  def to_classifier_input(_), do: ""
end
