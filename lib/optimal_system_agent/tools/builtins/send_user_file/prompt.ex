defmodule OptimalSystemAgent.Tools.Builtins.SendUserFile.Prompt do
  @moduledoc """
  Dynamic prompt for the `send_user_file` tool.

  Cross-references `send_message` — this tool is the file-delivery complement
  to send_message's text delivery. Both surface content to the user.
  """

  alias OptimalSystemAgent.Tools.Builtins.SendUserFile.Constants

  def render(_opts \\ []) do
    """
    Send a file to the user — emits an event on the Events.Bus that the
    frontend picks up for download, drag-drop, or mobile attachment delivery.

    Use this when you have produced or located a file the user needs:
    - A generated report, chart, or export
    - A log file from a completed task
    - A patched file ready for download

    For small text files (< #{div(Constants.inline_size_limit_bytes(), 1024)}KB) with a previewable extension,
    the file content is also included inline in the event so the frontend can
    render a preview. Larger files get a path reference only.

    Previewable extensions: #{Enum.join(Constants.previewable_extensions(), ", ")}

    `path` — absolute path to the file (must exist and be readable)
    `label` — optional display name shown to the user (defaults to basename)
    `description` — optional one-line description of what the file contains

    This tool reads the file but its primary effect is user-side (the event).
    It does NOT copy or move the file — the path reference is stable.

    Pair with `send_message` (the text delivery counterpart) to accompany
    a file with a human-readable explanation.
    """
  end
end
