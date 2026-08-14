defmodule OptimalSystemAgent.Tools.Builtins.Git.Tool do
  @moduledoc """
  Structured-layout git tool implementation.

  Per-tool directory layout — declarations only, all logic in sibling modules:

    * `Git.Constants`  — exported atoms for cross-tool reference
    * `Git.Prompt`     — dynamic prompt with the full Git Safety Protocol
    * `Git.Handler`    — validate / check_permissions / execute
    * `Git.UI`         — render callbacks for the Rust TUI

  ## Loading semantics
  - `should_defer?` → false  (always-loaded — git is in the hot path)
  - `always_load?`  → true

  ## Execution semantics (per-input)
  - `concurrency_safe?` → false  (git operations on the same repo are not safe to interleave)
  - `read_only?`        → true for status/diff/log/show/branch/tag/remote; false otherwise
  - `destructive?`      → true for reset --hard, push --force, branch -D, clean -f
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Git.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["g"]

  @impl true
  def search_hint, do: "run git subcommands: status, diff, log, commit, add, branch, stash, tag"

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
        "command" => %{
          "type" => "string",
          "description" => "Git subcommand, e.g. status, diff, log, add, commit"
        },
        "args" => %{
          "type" => "string",
          "description" => "Additional flags and arguments. Optional."
        },
        "path" => %{
          "type" => "string",
          "description" => "Working directory. Defaults to ~/.osa/workspace."
        }
      },
      "required" => ["command"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────

  @impl true
  # git is in the hot path for any code-modification session — never defer.
  def should_defer?, do: false

  @impl true
  # Always inject git into the prompt so the model can reach it immediately.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────

  @impl true
  # git operations on the same repo are NOT safe to interleave — index locks,
  # race conditions on HEAD, and ref conflicts make concurrent git unsafe.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(%{"command" => command} = input, _ctx) do
    args_str = input["args"] || ""
    args_list = parse_args_simple(args_str)
    subcommand = String.trim(command)

    subcommand in Constants.read_only_subcommands() and
      not has_destructive_flags?(args_list)
  end

  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(%{"command" => command} = input, _ctx) do
    args_str = input["args"] || ""
    args_list = parse_args_simple(args_str)
    subcommand = String.trim(command)
    args_joined = Enum.join(args_list, " ")

    Enum.any?(Constants.destructive_combinations(), fn {cmd, arg_pattern} ->
      subcommand == cmd and String.contains?(args_joined, arg_pattern)
    end)
  end

  def destructive?(_input, _ctx), do: false

  @impl true
  # git is write-safe by default; specific inputs are classified by
  # read_only?/2 and destructive?/2 above.
  def safety, do: :write_safe

  # ── Two-stage permissioning ───────────────────────────────────────────

  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  # ── Execution ─────────────────────────────────────────────────────────

  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # Flat-layout compatibility: the test harness and LegacyAdapter may call execute/1.
  # Runs the full validate → check_permissions → execute pipeline so that
  # safety rules are enforced regardless of call path.
  @impl true
  def execute(input) do
    ctx = %OptimalSystemAgent.Tools.UseContext{}

    case Handler.validate(input, ctx) do
      {:ok, valid} ->
        case Handler.check_permissions(valid, ctx) do
          {:allow, allowed} ->
            Handler.execute(allowed, ctx)

          {:deny, reason} ->
            {:error, reason}

          {:ask, prompt} ->
            # Same interactive round-trip as the structured path
            # (LegacyAdapter → PermissionBroker); a decline is a non-fatal,
            # model-readable refusal, never an internal error string.
            case OptimalSystemAgent.Permissions.AskFlow.request(name(), valid, ctx, prompt) do
              :allow -> Handler.execute(valid, ctx)
              {:error, reason} -> {:error, reason}
            end
        end

      {:error, msg, _code} ->
        {:error, msg}
    end
  end

  # ── Rendering ─────────────────────────────────────────────────────────

  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ──────────────────────────────────────────────────

  @impl true
  def to_classifier_input(%{"command" => cmd} = input) do
    %{command: cmd, args: input["args"]}
  end

  def to_classifier_input(_), do: ""

  # ── Private ───────────────────────────────────────────────────────────

  # Lightweight arg splitter for read_only?/destructive? — no quote handling
  # needed since we only inspect flag patterns.
  defp parse_args_simple(""), do: []

  defp parse_args_simple(str) do
    str |> String.trim() |> String.split(~r/\s+/, trim: true)
  end

  defp has_destructive_flags?(args) do
    Enum.any?(Constants.destructive_flag_patterns(), fn flag ->
      flag in args
    end)
  end
end
