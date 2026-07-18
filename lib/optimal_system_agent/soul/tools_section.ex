defmodule OptimalSystemAgent.Soul.ToolsSection do
  @moduledoc """
  Builds the `{{TOOL_DEFINITIONS}}` block for the static system-prompt.

  Replaces the old `description/0`-based loop in `Soul.tools_content/0` with
  a single call to `Tools.PromptAssembler.assemble/3`, which:

  1. Calls each structured tool's `prompt/1` callback (dynamic, cross-tool refs)
  2. Falls back to `description/0` for flat-layout tools
  3. Returns `{loaded_section, deferred_names}` — the two halves of the output

  The loaded section becomes the body of `## Available Tools`.
  Non-empty deferred names are appended as a `<system-reminder>` block
  mirroring the the upstream agent CLI pattern at
  upstream.

  ## Format contract

  The output string always starts with `## Available Tools` so it is
  drop-in compatible with the existing `{{TOOL_DEFINITIONS}}` interpolation
  in SYSTEM.md.  When there are no loaded tools the function returns `nil`
  (same as the previous implementation), which causes `Soul.interpolate/3`
  to erase the `{{TOOL_DEFINITIONS}}` marker without leaving a blank block.
  """

  require Logger

  alias OptimalSystemAgent.Tools.{PromptAssembler, Registry, UseContext}

  # Core tools inlined into the LITE static base. Mirrors ToolFilter's runtime
  # allowlist (@priority_tools + the always-on file/task/memory/tool_search set)
  # so the prompt's tool-defs match the tools a local model can actually call.
  @core_tools ~w(file_read file_write file_edit file_grep file_glob dir_list
    shell_execute task_write ask_user memory_recall memory_save tool_search)

  @doc """
  Returns the full tool-definitions block for the system prompt, or `nil`
  when no tools are available.

  Catches all errors so a registry crash never prevents boot.
  """
  @spec build() :: String.t() | nil
  def build, do: do_build([])

  @doc """
  LITE variant of `build/0`: only the core-tool allowlist (`@core_tools`) is
  inlined; EVERY other tool is forced to the deferred side — advertised by name
  in the `<system-reminder>` block and loadable via tool_search — REGARDLESS of
  its `always_load?/0`. This is what drops the static base from ~24k to ~4-6k for
  local providers / small windows.
  """
  @spec build(:lite) :: String.t() | nil
  def build(:lite), do: do_build(only: &(&1 in @core_tools))

  defp do_build(opts) do
    tool_modules = fetch_builtin_modules()

    case tool_modules do
      [] ->
        nil

      mods ->
        ctx = build_use_context(mods)

        {loaded_section, deferred_names} =
          PromptAssembler.assemble(mods, ctx, opts)

        render(loaded_section, deferred_names)
    end
  rescue
    err ->
      Logger.warning("[Soul.ToolsSection] build failed: #{Exception.message(err)}")
      nil
  end

  # ── Private ───────────────────────────────────────────────────────────────

  # Retrieve all builtin tool modules from the Registry's persistent_term store.
  # We need *modules* (not the map-based tool specs) because PromptAssembler
  # calls `mod.prompt/1`, `mod.name/0`, etc. directly.
  defp fetch_builtin_modules do
    :persistent_term.get({Registry, :builtin_tools}, %{})
    |> Map.values()
  catch
    :exit, _ -> []
  end

  # Build a minimal UseContext carrying the tool module list so that
  # cross-tool `safe_ref` helpers inside `prompt/1` callbacks can resolve
  # live tool names. We don't have a real agent session at prompt-assembly
  # time so non-tool fields stay at their safe defaults.
  defp build_use_context(tool_modules) do
    UseContext.new(%{}, tools: tool_modules, agents: [])
  end

  defp render("", []), do: nil
  defp render("", _deferred), do: nil

  defp render(loaded_section, deferred_names) do
    base = "## Available Tools\n\n#{loaded_section}"

    if deferred_names == [] do
      base
    else
      reminder = build_deferred_reminder(deferred_names)
      base <> "\n\n" <> reminder
    end
  end

  defp build_deferred_reminder(names) do
    items = Enum.map_join(names, "\n", fn name -> "- #{name}" end)

    """
    <system-reminder>
    The following deferred tools are available via tool_search but are not loaded by default:
    #{items}
    </system-reminder>
    """
    |> String.trim_trailing()
  end
end
