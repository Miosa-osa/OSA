defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.Prompt do
  @moduledoc """
  Dynamic prompt for `send_message`.

  The tool description carries the DOCTRINE, not just the schema. The channel
  is an interruption of a conversation between the user and the lead agent, and
  a model given only a schema will use it for progress reports — which is the
  one thing that makes the channel worthless. So the description states the
  three cases that qualify, the cases that never do, and the tie-breaker for
  everything in between.
  """

  alias OptimalSystemAgent.Tools.Builtins.SendMessage.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Send a message to another running agent — or to the user — by name or session ID.

    The target receives the message injected into its context on the next reasoning
    iteration. Messages addressed to the user appear immediately in their session.

    ```json
    {"to": "researcher", "message": "start on task #1"}
    {"to": "user", "message": "the auth module has no tests at all — worth knowing before I keep going"}
    ```

    | `to` | |
    |---|---|
    | `"user"` | The session that delegated you — the human, via the lead agent |
    | `"researcher"` | Teammate by name |
    | `"*"` | Broadcast to all teammates (expensive — use only when everyone needs it) |
    | `"session_..."` | Direct session ID |

    Your plain text output is NOT visible to other agents — to communicate, you MUST
    call this tool. Messages from teammates are delivered automatically; you don't
    check an inbox. Refer to teammates by name, never by UUID.

    ## When to message the user

    Speak only when NOT speaking costs them something. Three cases qualify:

      1. **A discovery that changes the shape of the task.** Not "this is hard" —
         something that means the work they asked for is not the work that needs
         doing.
      2. **An ambiguity you are about to resolve by guessing.** Say which way you
         are about to go, so they can stop you cheaply instead of reading it in
         your report after you have built the wrong thing.
      3. **A decision that is expensive to reverse later and cheap to redirect
         now.** Schema, file layout, a dependency, a migration.

    Never for progress. Never per-tool. Never "I started" or "I'm on step 3".
    Never anything that will still be true and still be readable in your final
    report — the report is read in full, so everything else belongs there.

    If you are unsure whether it qualifies, it does not. You are interrupting a
    conversation between the user and someone else.

    ## Budget

    #{Constants.max_messages_per_run()} messages per run, hard, with at least
    #{div(Constants.min_spacing_ms(), 1000)}s between them and none in the first
    #{div(Constants.warmup_ms(), 1000)}s. Messages are cut at
    #{Constants.max_message_chars()} characters, so lead with the finding — one
    sentence, no preamble, no restating your assignment. Spend the budget the way
    you would spend an interruption in person.
    """
  end
end
