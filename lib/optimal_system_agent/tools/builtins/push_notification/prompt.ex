defmodule OptimalSystemAgent.Tools.Builtins.PushNotification.Prompt do
  @moduledoc """
  Dynamic prompt for the `push_notification` tool.

  Cross-references `send_message` since both surface information to the
  user — this one at the OS level, send_message through the in-app channel.
  """

  alias OptimalSystemAgent.Tools.Builtins.PushNotification.Constants

  def render(_opts \\ []) do
    """
    Send an OS-level push notification to the user's desktop.

    Use this when you need to surface a result or alert outside the current
    session view — e.g. a background job finished, a monitored condition
    triggered, a build completed, or an error requires immediate attention.

    Prefer `send_message` (in-app) for normal conversational replies.
    Use `push_notification` only for out-of-band signals the user needs
    to see even if they have stepped away from the terminal.

    On macOS the notification appears in Notification Centre via `osascript`.
    On Linux it uses `notify-send`. On other platforms it degrades gracefully
    to a log entry.

    `title` — short headline (max #{Constants.max_title_chars()} chars)
    `body`  — detail text (max #{Constants.max_body_chars()} chars)
    `urgency` — one of: #{Enum.join(Constants.valid_urgency(), ", ")} (default: #{Constants.default_urgency()})
    """
  end
end
