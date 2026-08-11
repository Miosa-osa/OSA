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
    shell_execute task_write ask_user memory_recall memory_save tool_search
    delegate list_agents use_skill web_fetch)

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
    hidden = Registry.model_hidden()

    :persistent_term.get({Registry, :builtin_tools}, %{})
    # Harness/UI/redundant tools stay registered + searchable but are kept out
    # of the model's system-prompt toolbox (a lean, CC-style default set).
    |> Enum.reject(fn {name, _mod} -> MapSet.member?(hidden, name) end)
    |> Enum.map(fn {_name, mod} -> mod end)
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

    parts =
      [
        base,
        if(deferred_names == [], do: nil, else: build_deferred_reminder(deferred_names)),
        build_mcp_catalog()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n\n")
  end

  # ── MCP catalog ───────────────────────────────────────────────────────────
  #
  # `fetch_builtin_modules/0` reads ONLY `{Registry, :builtin_tools}`, so MCP
  # tools have never appeared in this section — not as loaded schemas, and not
  # even as names in the deferred reminder. Above the virtualization threshold
  # (`MCP.Virtualization`, default 10) every MCP tool is also stripped from
  # `Registry.list_active/0`, i.e. from the provider `tools` array. The net
  # effect was that a configured MCP server left NO trace anywhere the model
  # could see: it could not use what it had no evidence existed.
  #
  # This block is the evidence. It names every server and every tool it offers,
  # so the model can go straight to `tool_search` with an exact name or a
  # `server:` enumeration. Schemas stay deferred — only the catalog is cheap
  # (one line per tool) and always present.
  defp build_mcp_catalog do
    catalog = Registry.mcp_catalog()

    deferred_catalog =
      catalog
      |> Enum.map(fn {server, entries} -> {server, Enum.filter(entries, & &1.deferred?)} end)
      |> Enum.reject(fn {_server, entries} -> entries == [] end)
      |> Enum.sort_by(fn {server, _} -> server end)

    if deferred_catalog == [] do
      nil
    else
      total = deferred_catalog |> Enum.map(fn {_s, e} -> length(e) end) |> Enum.sum()

      servers =
        Enum.map_join(deferred_catalog, "\n", fn {server, entries} ->
          tools = Enum.map_join(entries, ", ", & &1.tool)
          "- **#{server}** (#{length(entries)} tools): #{tools}"
        end)

      """
      <mcp-servers>
      #{total} MCP tool(s) across #{length(deferred_catalog)} connected server(s) are available but NOT loaded — their schemas are deferred to keep this prompt small. They are real, callable tools; you just need to fetch a schema first.

      #{servers}

      To use one, call `tool_search` first:
      - `select:mcp__<server>__<tool>` — fetch exact schemas (comma-separate several)
      - `server:<server>` — list every tool on one server with its schema
      Then call the tool by its full `mcp__<server>__<tool>` name.
      </mcp-servers>
      """
      |> String.trim_trailing()
    end
  rescue
    err ->
      Logger.warning("[Soul.ToolsSection] MCP catalog build failed: #{Exception.message(err)}")
      nil
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
