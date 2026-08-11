defmodule OptimalSystemAgent.MCP.Client.OutputLimiter do
  @moduledoc """
  Bound MCP tool output that would otherwise flood the context window.

  Ports Claude Code's `MAX_MCP_OUTPUT_TOKENS` behaviour: text results larger
  than the cap (default 25,000 tokens, ~4 chars/token) are written to
  `~/.osa/tool-results/<id>.txt` and replaced with an instruction block that
  tells the model to read the file back in chunks. Image and error results
  pass through untouched.

  Precedence for the cap:
    1. `MAX_MCP_OUTPUT_TOKENS` env var (explicit user override)
    2. `:optimal_system_agent, :max_mcp_output_tokens` app env
    3. Hardcoded default (25,000)
  """

  require Logger

  @default_max_tokens 25_000
  @chars_per_token 4

  @doc """
  Apply the MCP output cap to a normalized tool result.

  Accepts OSA's tool-result shape (`{:ok, binary}` / `{:ok, {:image, ...}}` /
  `{:error, term}`) and returns the same shape, spilling oversize text.
  """
  @spec limit(term(), String.t(), String.t()) :: term()
  def limit({:ok, text}, server, tool) when is_binary(text) do
    max_chars = max_output_tokens() * @chars_per_token

    if String.length(text) > max_chars do
      {:ok, spill(text, server, tool)}
    else
      {:ok, text}
    end
  end

  def limit(other, _server, _tool), do: other

  @doc "The resolved MCP output token cap."
  @spec max_output_tokens() :: pos_integer()
  def max_output_tokens do
    case System.get_env("MAX_MCP_OUTPUT_TOKENS") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> app_default()
        end

      _ ->
        app_default()
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp app_default do
    Application.get_env(:optimal_system_agent, :max_mcp_output_tokens, @default_max_tokens)
  end

  defp spill(text, server, tool) do
    dir = results_dir()
    File.mkdir_p!(dir)

    safe_server = sanitize(server)
    safe_tool = sanitize(tool)
    id = "mcp_#{safe_server}_#{safe_tool}_#{System.unique_integer([:positive])}"
    path = Path.join(dir, id <> ".txt")

    case File.write(path, text) do
      :ok ->
        instructions(path, String.length(text))

      {:error, reason} ->
        Logger.warning(
          "[MCP.OutputLimiter] Failed to spill #{server}/#{tool}: #{inspect(reason)}"
        )

        truncate(text)
    end
  rescue
    _ -> truncate(text)
  end

  defp instructions(path, length) do
    "Error: result (#{length} characters) exceeds maximum allowed tokens. " <>
      "Output has been saved to #{path}.\n" <>
      "Format: Plain text\n" <>
      "Use offset and limit parameters to read specific portions of the file, " <>
      "search within it for specific content, and jq to make structured queries.\n" <>
      "REQUIREMENTS FOR SUMMARIZATION/ANALYSIS/REVIEW:\n" <>
      "- You MUST read the content from the file at #{path} in sequential chunks " <>
      "until 100% of the content has been read.\n" <>
      "- If you receive truncation warnings when reading the file, reduce the chunk " <>
      "size until you have read 100% of the content without truncation.\n" <>
      "- Before producing ANY summary or analysis, you MUST explicitly describe what " <>
      "portion of the content you have read. If you did not read the entire content, " <>
      "you MUST explicitly state this.\n"
  end

  defp truncate(text) do
    max_chars = max_output_tokens() * @chars_per_token

    String.slice(text, 0, max_chars) <>
      "\n\n[MCP output truncated — #{String.length(text)} chars total, showing first #{max_chars}]"
  end

  defp sanitize(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_\-]/, "_")
  end

  defp results_dir do
    config_dir =
      Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()

    Path.join(config_dir, "tool-results")
  end
end
