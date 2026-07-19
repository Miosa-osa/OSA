defmodule OptimalSystemAgent.Protocol.ContextRefs do
  @moduledoc """
  Resolves `OrchestrateRequest.context_refs` — the structured `@file` /
  `@agent` composer mentions the TUI carries alongside `input` — into real
  context the model actually sees, instead of the mention only surviving as
  inline prompt text.

  This is the backend half of the deferred composer `@`-mentions piece (see
  `priv/rust/tui/src/components/input/mentions.rs` for the TUI-side parser and
  typed `Attachment` enum). IMAGE mentions already ride `OrchestrateRequest`'s
  vision `images` field and are untouched by this module.

  Deliberately lives at the request/prompt-assembly boundary
  (`OrchestrateRoutes`), not inside `Agent.Loop`/`ReactLoop` — those modules
  only ever see a plain `input` string, so this stays backward-compatible by
  construction: an absent/empty `context_refs` list is a no-op and `input`
  passes through unchanged.
  """

  require Logger

  @type ref_map :: %{optional(String.t()) => term()}

  @max_file_bytes 200_000

  @doc """
  Resolve `context_refs` (as decoded from JSON — a list of maps with a
  `"type"` discriminator) into a context block, and return `input` with that
  block appended. Returns `input` unchanged when `context_refs` is nil/empty.

  * `"file"` refs are read from disk (resolved against `working_dir` when the
    path is relative) and injected as a fenced, path-labelled block. An
    optional `"range"` (`"10"` or `"10-20"`, 1-based, inclusive) slices the
    file to just those lines. A file that can't be read (missing, not a
    regular file, path escapes below) is noted as an error line rather than
    silently dropped, so the model — and the user — can see the mention
    failed to resolve.
  * `"agent"` refs are noted so the model knows an agent was explicitly
    requested by name; OSA has no sub-agent routing at this call boundary, so
    this is informational context, not a dispatch.
  """
  @spec inject(String.t(), [ref_map()] | nil, String.t() | nil) :: String.t()
  def inject(input, context_refs, working_dir \\ nil)

  def inject(input, nil, _working_dir), do: input
  def inject(input, [], _working_dir), do: input

  def inject(input, context_refs, working_dir) when is_list(context_refs) do
    case build_block(context_refs, working_dir) do
      "" -> input
      block -> input <> "\n\n" <> block
    end
  end

  def inject(input, _invalid, _working_dir), do: input

  @doc "Build the context block for a list of refs, or \"\" when nothing resolves."
  @spec build_block([ref_map()], String.t() | nil) :: String.t()
  def build_block(context_refs, working_dir) do
    context_refs
    |> Enum.map(&resolve_one(&1, working_dir))
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n\n")
  end

  # ── Per-ref resolution ──────────────────────────────────────────────────

  defp resolve_one(%{"type" => "file"} = ref, working_dir) do
    path = Map.get(ref, "path")
    resolve_file(path, Map.get(ref, "range"), working_dir)
  end

  defp resolve_one(%{"type" => "agent"} = ref, _working_dir) do
    case Map.get(ref, "name") do
      name when is_binary(name) and name != "" ->
        "<context-ref type=\"agent\" name=#{inspect(name)}>\n" <>
          "The user explicitly mentioned the \"#{name}\" agent/persona in this message via @#{name}.\n" <>
          "</context-ref>"

      _ ->
        nil
    end
  end

  defp resolve_one(_other, _working_dir) do
    Logger.debug("[ContextRefs] Skipping context_ref with unknown/missing type")
    nil
  end

  defp resolve_file(path, _range, _working_dir) when not is_binary(path) or path == "", do: nil

  defp resolve_file(path, range, working_dir) do
    resolved = resolve_path(path, working_dir)

    with true <- File.regular?(resolved),
         {:ok, contents} <- File.read(resolved) do
      contents = maybe_truncate(contents)
      {sliced, label_suffix} = slice_range(contents, range)

      "<context-ref type=\"file\" path=#{inspect(path)}#{label_suffix}>\n" <>
        sliced <> "\n</context-ref>"
    else
      _ ->
        "<context-ref type=\"file\" path=#{inspect(path)} error=\"unreadable\">\n" <>
          "(could not read this file — it may not exist or is not a regular file)\n" <>
          "</context-ref>"
    end
  end

  # Relative paths resolve against working_dir (the session's cwd); absolute
  # paths pass through untouched. Falls back to the raw path when no
  # working_dir is known, matching how the rest of the request already
  # treats an absent working_dir (tools resolve against the process cwd).
  defp resolve_path(path, working_dir) do
    if Path.type(path) == :absolute or is_nil(working_dir) or working_dir == "" do
      path
    else
      Path.join(working_dir, path)
    end
  end

  defp maybe_truncate(contents) when byte_size(contents) > @max_file_bytes do
    binary_part(contents, 0, @max_file_bytes) <> "\n... (truncated)"
  end

  defp maybe_truncate(contents), do: contents

  # `range` is "start" or "start-end", 1-based inclusive line numbers, as
  # produced by the TUI's `mentions::LineRange` (`#L10-20` / `#L5`).
  # Malformed ranges fall back to the full file rather than erroring the
  # whole ref, mirroring the TUI parser's own lenient behavior.
  defp slice_range(contents, range) when is_binary(range) and range != "" do
    lines = String.split(contents, "\n")

    case parse_range(range) do
      {start, stop} ->
        start_idx = max(start - 1, 0)
        stop_idx = min(stop - 1, length(lines) - 1)

        if start_idx <= stop_idx and start_idx < length(lines) do
          sliced =
            lines
            |> Enum.slice(start_idx..stop_idx)
            |> Enum.join("\n")

          {sliced, " range=\"#{start}-#{stop}\""}
        else
          {contents, ""}
        end

      :error ->
        {contents, ""}
    end
  end

  defp slice_range(contents, _range), do: {contents, ""}

  defp parse_range(range) do
    case String.split(range, "-", parts: 2) do
      [start_s] ->
        with {start, ""} <- Integer.parse(start_s) do
          {start, start}
        else
          _ -> :error
        end

      [start_s, end_s] ->
        with {start, ""} <- Integer.parse(start_s),
             {stop, ""} <- Integer.parse(end_s) do
          {start, stop}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
