defmodule OptimalSystemAgent.MCP.Transport.SSE do
  @moduledoc """
  Pure Server-Sent-Events framing helpers, shared by the HTTP MCP transport.

  SSE frames a byte stream into events separated by a blank line. Each event is
  a set of `field: value` lines; the fields MCP uses are `event` (type, default
  `"message"`), `data` (payload — multiple `data:` lines join with `\\n`), and
  `id` (the last-event id, for resumption). This module is a stateless parser:
  `parse/1` splits a *complete* buffer into `{events, remainder}` where the
  remainder is a trailing partial event to be prepended to the next chunk. It
  reads no sockets and holds no state, so every framing branch is unit-testable.

  Reference: opencode / grok both lean on the MCP SDK's SSE client; OSA has no
  such SDK, so this reproduces just the framing the transport needs.
  """

  @type event :: %{type: String.t(), data: String.t(), id: String.t() | nil}

  @doc """
  Split `buffer` into `{complete_events, remainder}`.

  Events are delimited by a blank line (`\\n\\n`, tolerant of `\\r\\n`). The
  remainder is whatever trails the last delimiter — a possibly-partial next
  event — and should be carried into the next `parse/1` call. Comment lines
  (starting `:`) and events with no `data` are dropped.
  """
  @spec parse(binary()) :: {[event()], binary()}
  def parse(buffer) when is_binary(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")

    case Enum.reverse(parts) do
      [remainder | rev_complete] ->
        events =
          rev_complete
          |> Enum.reverse()
          |> Enum.map(&parse_event/1)
          |> Enum.reject(&is_nil/1)

        {events, remainder}

      [] ->
        {[], ""}
    end
  end

  @doc """
  Parse a single already-delimited event block into an `event()` or `nil`.

  `nil` when the block has no `data` field (e.g. a lone comment or heartbeat).
  """
  @spec parse_event(binary()) :: event() | nil
  def parse_event(block) when is_binary(block) do
    {type, data_lines, id} =
      block
      |> String.split("\n")
      |> Enum.reduce({"message", [], nil}, fn line, {type, data, id} ->
        cond do
          line == "" or String.starts_with?(line, ":") ->
            {type, data, id}

          true ->
            case split_field(line) do
              {"event", v} -> {v, data, id}
              {"data", v} -> {type, [v | data], id}
              {"id", v} -> {type, data, v}
              _ -> {type, data, id}
            end
        end
      end)

    case data_lines do
      [] -> nil
      _ -> %{type: type, data: data_lines |> Enum.reverse() |> Enum.join("\n"), id: id}
    end
  end

  # Split "field: value" (a single leading space after the colon is stripped,
  # per the SSE spec). A line with no colon is a field with an empty value.
  defp split_field(line) do
    case String.split(line, ":", parts: 2) do
      [field, value] -> {field, strip_leading_space(value)}
      [field] -> {field, ""}
    end
  end

  defp strip_leading_space(" " <> rest), do: rest
  defp strip_leading_space(v), do: v
end
