defmodule OptimalSystemAgent.Agent.Loop.Checkpoint do
  @moduledoc """
  Loop state persistence for crash recovery.

  Persists enough state after each completed tool-result cycle so that
  a crash-restarted Loop can resume without losing conversation context.
  """
  require Logger

  @doc "Returns the directory where checkpoint files are stored."
  def checkpoint_dir do
    Application.get_env(:optimal_system_agent, :checkpoint_dir, "~/.osa/checkpoints")
    |> Path.expand()
  end

  @doc "Returns the full path to the checkpoint file for the given session."
  def checkpoint_path(session_id) do
    Path.join(checkpoint_dir(), "#{session_id}.json")
  end

  @doc "Write a checkpoint for the given loop state."
  def checkpoint_state(state) do
    data = %{
      session_id: state.session_id,
      messages: state.messages,
      iteration: state.iteration,
      plan_mode: state.plan_mode,
      turn_count: state.turn_count,
      checkpointed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    dir = checkpoint_dir()
    File.mkdir_p!(dir)

    path = checkpoint_path(state.session_id)
    # Sanitize messages to valid UTF-8 before JSON encoding — codebase context
    # blocks may contain non-UTF-8 bytes from binary file reads.
    sanitized =
      update_in(data, [:messages], fn msgs ->
        Enum.map(msgs, fn
          %{content: c} = m when is_binary(c) -> %{m | content: sanitize_utf8(c)}
          %{"content" => c} = m when is_binary(c) -> %{m | "content" => sanitize_utf8(c)}
          m -> m
        end)
      end)

    File.write!(path, Jason.encode!(sanitized), [:utf8])

    Logger.debug(
      "[loop] Checkpoint written for session #{state.session_id} at iteration #{state.iteration}"
    )
  rescue
    e ->
      Logger.warning("[loop] Checkpoint write failed: #{Exception.message(e)}")
  end

  @doc "Restore a checkpoint for the given session. Returns a map of state fields, or %{} if none exists."
  def restore_checkpoint(session_id) do
    path =
      Application.get_env(:optimal_system_agent, :checkpoint_dir, "~/.osa/checkpoints")
      |> Path.expand()
      |> Path.join("#{session_id}.json")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} ->
              messages =
                (data["messages"] || [])
                |> Enum.map(fn msg when is_map(msg) ->
                  for {k, v} <- msg, into: %{} do
                    {String.to_atom(k), v}
                  end
                end)

              %{
                messages: messages,
                iteration: data["iteration"] || 0,
                plan_mode: data["plan_mode"] || false,
                turn_count: data["turn_count"] || 0
              }

            {:error, _} ->
              Logger.warning("[loop] Checkpoint decode failed for session #{session_id}")
              %{}
          end

        {:error, _} ->
          %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp sanitize_utf8(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8) do
      {:error, valid, _} -> valid
      {:incomplete, valid, _} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  defp sanitize_utf8(other), do: to_string(other)

  @doc "Delete the checkpoint file for the given session."
  def clear_checkpoint(session_id) do
    path =
      Application.get_env(:optimal_system_agent, :checkpoint_dir, "~/.osa/checkpoints")
      |> Path.expand()
      |> Path.join("#{session_id}.json")

    File.rm(path)
    :ok
  rescue
    _ -> :ok
  end
end
