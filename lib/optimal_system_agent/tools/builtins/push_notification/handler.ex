defmodule OptimalSystemAgent.Tools.Builtins.PushNotification.Handler do
  @moduledoc """
  Validation, permission, and execution for `push_notification`.

  Shells out to the platform-appropriate notification command:
  - macOS  : `osascript -e 'display notification ...'`
  - Linux  : `notify-send`
  - Other  : degrades to a Logger warning (no crash)

  The OS notification system is considered an "open world" side effect
  (open_world? true on the Tool module). No abort_ref polling needed —
  the command is fast (<100ms) and not interruptible in a meaningful way.
  """

  alias OptimalSystemAgent.Tools.Builtins.PushNotification.Constants
  alias OptimalSystemAgent.Tools.UseContext
  require Logger

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"title" => title, "body" => body} = input, _ctx)
      when is_binary(title) and is_binary(body) do
    urgency = Map.get(input, "urgency", Constants.default_urgency())

    cond do
      String.trim(title) == "" ->
        {:error, "title must not be blank", -32_602}

      String.length(title) > Constants.max_title_chars() ->
        {:error, "title exceeds #{Constants.max_title_chars()} characters", -32_602}

      String.trim(body) == "" ->
        {:error, "body must not be blank", -32_602}

      String.length(body) > Constants.max_body_chars() ->
        {:error, "body exceeds #{Constants.max_body_chars()} characters", -32_602}

      urgency not in Constants.valid_urgency() ->
        {:error, "urgency must be one of: #{Enum.join(Constants.valid_urgency(), ", ")}", -32_602}

      true ->
        {:ok, Map.put_new(input, "urgency", Constants.default_urgency())}
    end
  end

  def validate(%{"title" => _, "body" => _}, _ctx),
    do: {:error, "title and body must be strings", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: title, body", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"urgency" => "critical"} = input, %UseContext{permission_mode: :strict}) do
    {:deny, "Access denied: critical notifications require non-strict permission mode"}
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{"title" => title, "body" => body} = input, _ctx) do
    urgency = Map.get(input, "urgency", Constants.default_urgency())

    case platform() do
      :macos -> send_macos(title, body)
      :linux -> send_linux(title, body, urgency)
      :other -> send_fallback(title, body, urgency)
    end
  end

  # ── Platform detection ─────────────────────────────────────────────────

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, _} -> if find_executable("notify-send"), do: :linux, else: :other
      _ -> :other
    end
  end

  defp find_executable(cmd), do: System.find_executable(cmd)

  # ── macOS ──────────────────────────────────────────────────────────────

  defp send_macos(title, body) do
    # Escape double-quotes in title/body to prevent AppleScript injection
    safe_title = String.replace(title, ~s("), ~s(\\"))
    safe_body = String.replace(body, ~s("), ~s(\\"))

    script = ~s(display notification "#{safe_body}" with title "#{safe_title}" subtitle "OSA")

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {_out, 0} ->
        {:ok, "Notification sent (macOS): #{title}"}

      {err, code} ->
        Logger.warning("[PushNotification] osascript exited #{code}: #{String.trim(err)}")
        {:error, "Notification failed (exit #{code}): #{String.trim(err)}"}
    end
  rescue
    e ->
      Logger.warning("[PushNotification] osascript error: #{Exception.message(e)}")
      {:error, "Notification failed: #{Exception.message(e)}"}
  end

  # ── Linux ──────────────────────────────────────────────────────────────

  defp send_linux(title, body, urgency) do
    args = ["-u", urgency, "-a", "OSA", title, body]

    case System.cmd("notify-send", args, stderr_to_stdout: true) do
      {_out, 0} ->
        {:ok, "Notification sent (Linux): #{title}"}

      {err, code} ->
        Logger.warning("[PushNotification] notify-send exited #{code}: #{String.trim(err)}")
        {:error, "Notification failed (exit #{code}): #{String.trim(err)}"}
    end
  rescue
    e ->
      Logger.warning("[PushNotification] notify-send error: #{Exception.message(e)}")
      {:error, "Notification failed: #{Exception.message(e)}"}
  end

  # ── Fallback ───────────────────────────────────────────────────────────

  defp send_fallback(title, body, urgency) do
    Logger.info("[PushNotification] #{urgency} | #{title}: #{body}")
    {:ok, "Notification logged (no OS notifier available): #{title}"}
  end
end
