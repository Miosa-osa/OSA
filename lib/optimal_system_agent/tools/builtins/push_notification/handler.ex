defmodule OptimalSystemAgent.Tools.Builtins.PushNotification.Handler do
  @moduledoc """
  Validation, permission, and execution for `push_notification`.

  Shells out to the platform-appropriate notification command:
  - macOS  : `terminal-notifier` when installed, else `osascript`
  - Linux  : `notify-send`
  - Other  : degrades to a Logger warning (no crash)

  ## Why `terminal-notifier` is preferred on macOS

  `osascript -e 'display notification'` is attributed by macOS to the script
  host, so the toast always carries Script Editor's icon, cannot be clicked
  through to anything, and stacks one entry per call. `terminal-notifier`
  supports `-group` (replace the previous OSA toast instead of piling up) and
  `-sender` (borrow an app's identity, which supplies both the icon and a
  click target). It is optional: without it delivery still works, it just
  looks like it always did.

  Set `OSA_NOTIFY_SENDER` to your terminal's bundle id - `com.github.wez.wezterm`,
  `com.apple.Terminal`, ... - to make clicking the toast raise that app.

  ## Focus gate

  A notification exists to reach someone who is not looking. Firing one at a
  user who is watching the screen is pure noise, so delivery is skipped while a
  terminal is frontmost (detected with `lsappinfo`, which needs no Accessibility
  permission, unlike System Events). `critical` urgency always goes through, and
  `OSA_NOTIFY_WHEN_FOCUSED=1` disables the gate. `OSA_NO_NOTIFY` silences
  everything.

  The check is a heuristic: it cannot tell OSA's terminal from any other, so
  sitting in an unrelated terminal also suppresses. That is the right trade for
  a notification whose whole purpose is to interrupt someone who stepped away.

  The OS notification system is considered an "open world" side effect
  (open_world? true on the Tool module). No abort_ref polling needed —
  the command is fast (<100ms) and not interruptible in a meaningful way.
  """

  alias OptimalSystemAgent.Events.Bus
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
  def execute(%{"title" => title, "body" => body} = input, ctx) do
    urgency = Map.get(input, "urgency", Constants.default_urgency())

    result =
      cond do
        disabled?() ->
          {:ok, "Notification suppressed (OSA_NO_NOTIFY): #{title}"}

        focus_suppressed?(urgency) ->
          # Still logged, so the intent is recoverable from the transcript even
          # though nothing was shown.
          Logger.info("[PushNotification] suppressed (focused) | #{title}: #{body}")
          {:ok, "Notification suppressed (you are at the terminal): #{title}"}

        true ->
          case platform() do
            :macos -> send_macos(title, body)
            :linux -> send_linux(title, body, urgency)
            :other -> send_fallback(title, body, urgency)
          end
      end

    # Surface the notification in the TUI as well (in addition to the OS-level
    # notifier). The TuiForwarder allowlists `push_notification` and bridges this
    # Bus :system_event onto the session topic the TUI streams.
    maybe_emit_event(ctx, title, body, urgency)

    result
  end

  defp maybe_emit_event(ctx, title, body, urgency) do
    session_id = ctx && Map.get(ctx, :session_id)

    if is_binary(session_id) do
      Bus.emit(:system_event, %{
        event: :push_notification,
        session_id: session_id,
        title: title,
        body: body,
        urgency: urgency
      })
    end

    :ok
  rescue
    _ -> :ok
  catch
    # A GenServer.call to a dead bus EXITS rather than raising, so `rescue`
    # alone let a stopped Events supervisor take down the whole tool call - the
    # notification had already been delivered by this point, and the mirror into
    # the TUI is strictly a nice-to-have.
    :exit, _ -> :ok
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
    case find_exe("terminal-notifier") do
      nil -> send_macos_osascript(title, body)
      path -> send_macos_terminal_notifier(path, title, body)
    end
  end

  defp send_macos_terminal_notifier(path, title, body) do
    # No shell is involved, so title/body go through as literal argv - there is
    # nothing to escape and nothing to inject into.
    args =
      [
        "-title",
        title,
        "-subtitle",
        "OSA",
        "-message",
        body,
        # One rolling OSA slot rather than a growing column of toasts.
        "-group",
        "com.miosa.osa"
      ] ++ sender_args()

    case run_cmd(path, args) do
      {_out, 0} ->
        {:ok, "Notification sent (macOS): #{title}"}

      {err, code} ->
        Logger.warning("[PushNotification] terminal-notifier exited #{code}: #{String.trim(err)}")
        {:error, "Notification failed (exit #{code}): #{String.trim(err)}"}
    end
  rescue
    e ->
      Logger.warning("[PushNotification] terminal-notifier error: #{Exception.message(e)}")
      {:error, "Notification failed: #{Exception.message(e)}"}
  end

  # Two flags, because they age differently. `-activate` names the app to raise
  # when the toast is clicked and is still honoured. `-sender` also borrows that
  # app's identity, which is what would supply its icon - recent macOS validates
  # the posting bundle and ignores the masquerade, so the toast keeps
  # terminal-notifier's own icon. Still better than Script Editor's scroll, and
  # harmless where `-sender` does work, so both are sent.
  defp sender_args do
    case System.get_env("OSA_NOTIFY_SENDER") do
      id when is_binary(id) ->
        if String.trim(id) == "", do: [], else: ["-activate", id, "-sender", id]

      _ ->
        []
    end
  end

  defp send_macos_osascript(title, body) do
    # Escape double-quotes in title/body to prevent AppleScript injection
    safe_title = String.replace(title, ~s("), ~s(\\"))
    safe_body = String.replace(body, ~s("), ~s(\\"))

    script = ~s(display notification "#{safe_body}" with title "#{safe_title}" subtitle "OSA")

    case run_cmd("osascript", ["-e", script]) do
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

    case run_cmd("notify-send", args) do
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

  # ── Delivery seams ─────────────────────────────────────────────────────
  #
  # Every OS command this module runs goes through these two functions. The
  # suite used to invoke the real `osascript` on every run, so `mix test`
  # posted "MyTitle / b" to the operator's Notification Centre - a test that
  # reaches the desktop is a test that cannot be run while working.

  @doc false
  def run_cmd(cmd, args) do
    case Application.get_env(:optimal_system_agent, :notification_runner) do
      runner when is_function(runner, 2) -> runner.(cmd, args)
      _ -> System.cmd(cmd, args, stderr_to_stdout: true)
    end
  end

  @doc false
  def find_exe(cmd) do
    case Application.get_env(:optimal_system_agent, :notification_executables) do
      %{} = overrides -> Map.get(overrides, cmd)
      _ -> System.find_executable(cmd)
    end
  end

  # ── Focus gate ─────────────────────────────────────────────────────────

  @terminal_bundle_ids ~w(
    com.github.wez.wezterm
    com.apple.Terminal
    com.googlecode.iterm2
    com.mitchellh.ghostty
    io.alacritty
    net.kovidgoyal.kitty
    org.tabby
    dev.warp.Warp-Stable
    co.zeit.hyper
    com.microsoft.VSCode
  )

  defp disabled?, do: System.get_env("OSA_NO_NOTIFY") not in [nil, ""]

  @doc false
  def focus_suppressed?(urgency) do
    cond do
      # An interruption the caller marked critical is not noise by definition.
      urgency == "critical" -> false
      System.get_env("OSA_NOTIFY_WHEN_FOCUSED") not in [nil, ""] -> false
      :os.type() != {:unix, :darwin} -> false
      true -> terminal_frontmost?()
    end
  end

  @doc false
  def terminal_frontmost? do
    frontmost_bundle_id() in @terminal_bundle_ids
  end

  # `lsappinfo` answers without the Accessibility prompt that System Events
  # would raise. Any failure returns nil, which fails OPEN: a detector that
  # breaks must not silently swallow every notification.
  defp frontmost_bundle_id do
    with {asn, 0} <- run_cmd("lsappinfo", ["front"]),
         asn = String.trim(asn),
         true <- asn != "",
         {info, 0} <- run_cmd("lsappinfo", ["info", "-only", "bundleid", asn]) do
      parse_bundle_id(info)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # `lsappinfo` prints `"CFBundleIdentifier"="com.github.wez.wezterm"`.
  @doc false
  def parse_bundle_id(output) when is_binary(output) do
    case Regex.run(~r/"CFBundleIdentifier"\s*=\s*"([^"]+)"/, output) do
      [_, id] -> id
      _ -> nil
    end
  end

  def parse_bundle_id(_), do: nil
end
