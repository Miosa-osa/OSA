defmodule OptimalSystemAgent.ContextRefs.Resolvers.File do
  @moduledoc """
  Resolves `@file:path` and bare `@path` references by reading local
  filesystem paths.

  Relative paths resolve against the session `working_dir` (threaded from the
  turn payload through the context_refs hook), falling back to the backend
  process cwd — the two differ for daemon/remote backends. Directory mentions
  emit a capped entry listing (Claude Code attachments.ts model, cap 1000)
  instead of a read error, and binary files are refused rather than spliced
  into the prompt as garbage.
  """

  @max_dir_entries 1000

  @spec resolve(
          String.t(),
          {integer() | nil, integer() | nil},
          pos_integer(),
          String.t() | nil
        ) :: {:ok, map()} | {:error, map()}
  def resolve(path, range, budget, working_dir \\ nil) do
    expanded = expand(path, working_dir)

    if File.dir?(expanded) do
      resolve_directory(path, expanded, budget)
    else
      resolve_file(path, expanded, range, budget)
    end
  end

  defp resolve_file(path, expanded, range, budget) do
    case File.read(expanded) do
      {:ok, content} ->
        if binary_content?(content) do
          {:error,
           %{
             type: :error,
             source: "@file:#{path}",
             content: "[Binary file #{path} (#{byte_size(content)} bytes) not attached]"
           }}
        else
          sliced = apply_range(content, range)
          truncated = String.slice(sliced, 0, budget)
          label = format_label(path, range)
          {:ok, %{type: :file, source: label, content: "```\n#{truncated}\n```"}}
        end

      {:error, reason} ->
        {:error,
         %{
           type: :error,
           source: "@file:#{path}",
           content: "[Error reading #{path}: #{reason}]"
         }}
    end
  end

  # Directory mention → capped listing (dirs marked with a trailing slash),
  # mirroring Claude Code's MAX_DIR_ENTRIES=1000 directory attachment.
  defp resolve_directory(path, expanded, budget) do
    case File.ls(expanded) do
      {:ok, entries} ->
        total = length(entries)

        names =
          entries
          |> Enum.sort()
          |> Enum.take(@max_dir_entries)
          |> Enum.map(fn entry ->
            if File.dir?(Path.join(expanded, entry)), do: entry <> "/", else: entry
          end)

        names =
          if total > @max_dir_entries do
            names ++ ["... and #{total - @max_dir_entries} more entries"]
          else
            names
          end

        listing = String.slice(Enum.join(names, "\n"), 0, budget)
        {:ok, %{type: :directory, source: "@dir:#{path}", content: listing}}

      {:error, reason} ->
        {:error,
         %{
           type: :error,
           source: "@file:#{path}",
           content: "[Error listing directory #{path}: #{reason}]"
         }}
    end
  end

  defp expand(path, nil), do: Path.expand(path)
  defp expand(path, working_dir), do: Path.expand(path, working_dir)

  # Null-byte sniff on the first 8KB (git's heuristic) plus a full UTF-8
  # validity check, so binary content never lands inside a prompt code fence
  # and String.slice/String.split never see invalid UTF-8.
  defp binary_content?(content) do
    sample = binary_part(content, 0, min(byte_size(content), 8192))
    :binary.match(sample, <<0>>) != :nomatch or not String.valid?(content)
  end

  defp apply_range(content, {nil, nil}), do: content

  defp apply_range(content, {start_line, nil}) do
    content |> String.split("\n") |> Enum.drop(start_line - 1) |> Enum.join("\n")
  end

  defp apply_range(content, {start_line, end_line}) do
    content
    |> String.split("\n")
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.join("\n")
  end

  defp format_label(path, {nil, nil}), do: "@file:#{path}"
  defp format_label(path, {start_line, nil}), do: "@file:#{path}:#{start_line}-"
  defp format_label(path, {start_line, end_line}), do: "@file:#{path}:#{start_line}-#{end_line}"
end
