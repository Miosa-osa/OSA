defmodule OptimalSystemAgent.Tools.Builtins.SendUserFile.Handler do
  @moduledoc """
  Validation, permission, and execution for `send_user_file`.

  Validates the path, optionally reads inline content for small previewable
  files, then emits a `:system_event` on Events.Bus with subtype
  "send_user_file". The frontend subscribes to this event type and presents
  the file to the user (download link, drag-drop, etc.).
  """

  alias OptimalSystemAgent.Tools.Builtins.SendUserFile.Constants
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Events.Bus
  require Logger

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path} = input, _ctx) when is_binary(path) do
    label = Map.get(input, "label")
    description = Map.get(input, "description")

    cond do
      String.trim(path) == "" ->
        {:error, "path must not be blank", -32_602}

      label != nil and not is_binary(label) ->
        {:error, "label must be a string", -32_602}

      description != nil and not is_binary(description) ->
        {:error, "description must be a string", -32_602}

      true ->
        expanded = Path.expand(path)
        {:ok, Map.put(input, "path", expanded)}
    end
  end

  def validate(%{"path" => _}, _ctx),
    do: {:error, "path must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: path", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    expanded = Path.expand(path)

    # Block path traversal outside of reasonable locations.
    # Allow anything under home dir, /tmp, or /var/folders (macOS tmp).
    home = System.user_home() || "/home"
    allowed_prefixes = [home, "/tmp", "/var/folders", "/private/tmp"]

    if Enum.any?(allowed_prefixes, &String.starts_with?(expanded, &1)) do
      {:allow, Map.put(input, "path", expanded)}
    else
      {:deny,
       "Access denied: send_user_file path must be under home, /tmp, or /var/folders. Got: #{expanded}"}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{"path" => path} = input, _ctx) do
    label = Map.get(input, "label", Path.basename(path))
    description = Map.get(input, "description", "")

    case File.stat(path) do
      {:error, reason} ->
        {:error, "Cannot read file #{path}: #{:file.format_error(reason)}"}

      {:ok, %{type: type}} when type != :regular ->
        {:error, "Path is not a regular file: #{path}"}

      {:ok, %{size: size}} ->
        inline_content = maybe_read_inline(path, size)

        payload = %{
          "subtype" => Constants.subtype(),
          "path" => path,
          "label" => label,
          "description" => description,
          "size_bytes" => size,
          "inline_content" => inline_content,
          "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        inline_note = if inline_content, do: " (inline preview included)", else: ""

        emit_result =
          try do
            Bus.emit(Constants.event_type(), payload, source: "send_user_file")
          rescue
            e ->
              Logger.warning("[SendUserFile] Bus.emit raised: #{Exception.message(e)}")
              :error
          catch
            :exit, reason ->
              Logger.info(
                "[SendUserFile] Bus.emit exit (supervisor not running?): #{inspect(reason)}"
              )

              :error
          end

        case emit_result do
          {:ok, _} ->
            {:ok, "File sent to user#{inline_note}: #{label} (#{format_size(size)}) at #{path}"}

          _ ->
            Logger.info("[SendUserFile] Bus unavailable — event not dispatched (path=#{path})")

            {:ok,
             "File queued for user#{inline_note}: #{label} (#{format_size(size)}) at #{path}"}
        end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp maybe_read_inline(path, size) do
    ext = Path.extname(path) |> String.downcase()

    if size <= Constants.inline_size_limit_bytes() and ext in Constants.previewable_extensions() do
      case File.read(path) do
        {:ok, content} -> content
        _ -> nil
      end
    else
      nil
    end
  end

  defp format_size(bytes) when bytes < 1_024, do: "#{bytes}B"
  defp format_size(bytes) when bytes < 1_024 * 1_024, do: "#{Float.round(bytes / 1_024, 1)}KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1_024 * 1_024), 1)}MB"
end
