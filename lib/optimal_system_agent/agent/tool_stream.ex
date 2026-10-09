defmodule OptimalSystemAgent.Agent.ToolStream do
  @moduledoc """
  Faithful tool-call records for machine consumers (`osa run --format stream-json`).

  The session topic (`"osa:session:<id>"`) carries a DISPLAY view of every tool
  call: `args` is `Loop.ToolHint.summarize/1` (a shell command clipped at 60
  characters, a file tool reduced to its path) and the result is a 2,000-char
  preview. That is right for the TUI and wrong for a consumer that must record
  exactly what the agent did, which is what a headless run's `tool_use` /
  `tool_result` events promise.

  So the faithful record travels on its OWN topic, `"osa:tool_stream:<id>"`,
  which only a headless runner subscribes to. The TUI stream is unchanged byte
  for byte, and a broadcast to a topic nobody subscribes to is a registry
  lookup and nothing else.

  Messages:

    * `{:osa_tool_stream, :use, %{id, name, input}}` - before approval, so a
      call that is then denied still has its `tool_use`.
    * `{:osa_tool_stream, :result, %{id, name, content, is_error, truncated}}`
      - the tool's result after post-tool hooks (before OSA appends its own
      `<system-reminder>` blocks), bounded by `max_content_bytes/0`.

  Both are sent from the process executing the call, so for one call the `:use`
  message always arrives before its `:result`.
  """

  @max_content_bytes 100_000

  @doc "The topic for one session's faithful tool records."
  @spec topic(String.t()) :: String.t()
  def topic(session_id), do: "osa:tool_stream:" <> to_string(session_id)

  @doc "Largest tool result content carried on the stream, in bytes."
  @spec max_content_bytes() :: pos_integer()
  def max_content_bytes, do: @max_content_bytes

  @doc "Publish the call as the model made it."
  @spec publish_use(String.t() | nil, map()) :: :ok
  def publish_use(session_id, tool_call) when is_binary(session_id) do
    broadcast(session_id, :use, %{
      id: Map.get(tool_call, :id),
      name: Map.get(tool_call, :name),
      input: public_input(Map.get(tool_call, :arguments))
    })
  end

  def publish_use(_session_id, _tool_call), do: :ok

  @doc "Publish the result text the model will read for this call."
  @spec publish_result(String.t() | nil, map(), String.t(), boolean()) :: :ok
  def publish_result(session_id, tool_call, content, failed?)
      when is_binary(session_id) and is_binary(content) do
    {content, truncated?} = bound(content)

    broadcast(session_id, :result, %{
      id: Map.get(tool_call, :id),
      name: Map.get(tool_call, :name),
      content: content,
      is_error: failed? == true,
      truncated: truncated?
    })
  end

  def publish_result(_session_id, _tool_call, _content, _failed?), do: :ok

  # The executor enriches arguments with `__session_id__`-style keys before
  # dispatch; those are plumbing, never part of what the model asked for.
  defp public_input(%{} = args) do
    args
    |> Enum.reject(fn {key, _} -> is_binary(key) and String.starts_with?(key, "__") end)
    |> Map.new()
  end

  defp public_input(_args), do: %{}

  defp bound(content) when byte_size(content) <= @max_content_bytes, do: {content, false}

  defp bound(content) do
    cut = binary_part(content, 0, @max_content_bytes)
    # Never split a UTF-8 sequence: drop a trailing partial codepoint.
    {trim_invalid_tail(cut), true}
  end

  defp trim_invalid_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_invalid_tail(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  defp broadcast(session_id, kind, payload) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      topic(session_id),
      {:osa_tool_stream, kind, payload}
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
