defmodule OptimalSystemAgent.Tools.Builtins.Pty.Shared do
  @moduledoc """
  Shared helpers for the `pty_*` builtin tools — condition parsing, session-id
  extraction, and screen formatting. Keeps the individual tool modules thin.
  """

  @doc "Extract the session id/name from the tool input (accepts a few aliases)."
  @spec session_id(map()) :: {:ok, String.t()} | {:error, String.t()}
  def session_id(input) do
    case input["session"] || input["session_id"] || input["id"] || input["name"] do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, "Missing required parameter: session"}
    end
  end

  @doc """
  Parse a wait-condition map into the internal tuple form.

  Accepts `%{"text" => s}`, `%{"regex" => s}`, `%{"gone" => true}`, or
  `%{"stable_ms" => n}`.
  """
  @spec parse_condition(map() | nil) :: {:ok, tuple() | :gone} | {:error, String.t()}
  def parse_condition(%{"text" => s}) when is_binary(s), do: {:ok, {:text, s}}
  def parse_condition(%{"regex" => s}) when is_binary(s), do: {:ok, {:regex, s}}
  def parse_condition(%{"gone" => true}), do: {:ok, :gone}
  def parse_condition(%{"stable_ms" => n}) when is_integer(n) and n >= 0, do: {:ok, {:stable_ms, n}}

  def parse_condition(cond) when is_map(cond),
    do: {:error, "condition must have exactly one of: text, regex, gone, stable_ms"}

  def parse_condition(_), do: {:error, "Missing required parameter: condition"}

  @doc "Render a wait outcome map as a compact, model-readable string."
  @spec format_outcome(map()) :: String.t()
  def format_outcome(outcome) do
    status =
      cond do
        outcome.matched -> "MATCHED"
        outcome.ended -> "NOT MATCHED (session ended — condition can never be met)"
        true -> "TIMEOUT (condition not met before deadline)"
      end

    """
    #{status} after #{outcome.elapsed_ms}ms (generation #{outcome.generation}).

    --- screen ---
    #{outcome.screen}
    --- cursor: row #{outcome.cursor.row}, col #{outcome.cursor.col} ---
    """
    |> String.trim_trailing()
  end
end
