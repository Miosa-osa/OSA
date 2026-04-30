defmodule OptimalSystemAgent.ContextRefs.Resolvers.File do
  @moduledoc "Resolves @file:path references by reading local filesystem paths."

  @spec resolve(String.t(), {integer() | nil, integer() | nil}, pos_integer()) ::
          {:ok, map()} | {:error, map()}
  def resolve(path, range, budget) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} ->
        sliced = apply_range(content, range)
        truncated = String.slice(sliced, 0, budget)
        label = format_label(path, range)
        {:ok, %{type: :file, source: label, content: "```\n#{truncated}\n```"}}

      {:error, reason} ->
        {:error,
         %{
           type: :error,
           source: "@file:#{path}",
           content: "[Error reading #{path}: #{reason}]"
         }}
    end
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
