defmodule OptimalSystemAgent.ContextRefs.Parser do
  @moduledoc "Extracts @ref tokens from user message text."

  @type ref ::
          {:file, String.t(), {non_neg_integer() | nil, non_neg_integer() | nil}}
          | {:diff, nil}
          | {:staged, nil}
          | {:git, pos_integer()}
          | {:url, String.t()}

  @ref_pattern ~r/
    @file:([^\s]+)          |  # @file:path\/to\/file.ex or @file:path:10-25
    @diff\b                 |  # @diff
    @staged\b               |  # @staged
    @git:(\d+)              |  # @git:5
    @url:(https?:\/\/[^\s]+)   # @url:https:\/\/example.com
  /x

  @spec parse(String.t()) :: {cleaned :: String.t(), refs :: [ref()]}
  def parse(message) when is_binary(message) do
    refs =
      Regex.scan(@ref_pattern, message)
      |> Enum.map(&match_to_ref/1)
      |> Enum.reject(&is_nil/1)

    cleaned =
      Regex.replace(@ref_pattern, message, "")
      |> String.trim()

    {cleaned, refs}
  end

  defp match_to_ref([full | _]) do
    cond do
      String.starts_with?(full, "@file:") ->
        raw = String.trim_leading(full, "@file:")
        parse_file_ref(raw)

      full == "@diff" ->
        {:diff, nil}

      full == "@staged" ->
        {:staged, nil}

      String.starts_with?(full, "@git:") ->
        n = full |> String.trim_leading("@git:") |> String.to_integer()
        {:git, max(n, 1)}

      String.starts_with?(full, "@url:") ->
        url = String.trim_leading(full, "@url:")
        {:url, url}

      true ->
        nil
    end
  end

  defp parse_file_ref(raw) do
    # Support @file:path.ex:10-25 line ranges
    case Regex.run(~r/^(.+):(\d+)-(\d+)$/, raw) do
      [_, path, start_line, end_line] ->
        {:file, path, {String.to_integer(start_line), String.to_integer(end_line)}}

      _ ->
        case Regex.run(~r/^(.+):(\d+)$/, raw) do
          [_, path, line] ->
            {:file, path, {String.to_integer(line), nil}}

          _ ->
            {:file, raw, {nil, nil}}
        end
    end
  end
end
