defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.Prompt do
  @moduledoc """
  Dynamic prompt for `send_message`.

  Mirrors `src/tools/SendMessageTool/prompt.ts`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Send a message to another running agent by name or session ID.

    The target agent will receive the message injected into its context on the next
    reasoning iteration. Use for inter-agent collaboration.

    ```json
    {"to": "researcher", "message": "start on task #1"}
    ```

    | `to` | |
    |---|---|
    | `"researcher"` | Teammate by name |
    | `"*"` | Broadcast to all teammates (expensive — use only when everyone needs it) |
    | `"session_..."` | Direct session ID |

    Your plain text output is NOT visible to other agents — to communicate, you MUST
    call this tool. Messages from teammates are delivered automatically; you don't
    check an inbox. Refer to teammates by name, never by UUID.
    """
  end
end
