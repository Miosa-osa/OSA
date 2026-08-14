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
    `to` also accepts `"*"` to broadcast to all teammates (expensive — only when
    everyone needs it).

    Your plain text output is NOT visible to other agents — to communicate you MUST call
    this tool. Incoming messages are delivered automatically; there is no inbox to check.
    Refer to teammates by name, never by UUID.

    ## When to message the user

    Speak only when NOT speaking costs them something:

      1. A discovery that changes the shape of the task — what they asked for is not
         what needs doing.
      2. An ambiguity you are about to resolve by guessing — say which way you are
         going, so they can stop you cheaply.
      3. A decision expensive to reverse and cheap to redirect now — schema, file
         layout, a dependency, a migration.

    Never for progress, never per-tool, never anything still true in your final report.
    If you are unsure it qualifies, it does not.

    ## Budget

    #{Constants.max_messages_per_run()} messages per run, hard; at least #{div(Constants.min_spacing_ms(), 1000)}s apart and none in the first #{div(Constants.warmup_ms(), 1000)}s.
    Cut at #{Constants.max_message_chars()} characters — lead with the finding, one sentence, no preamble.
    """
  end
end
