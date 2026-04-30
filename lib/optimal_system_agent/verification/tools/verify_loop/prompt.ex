defmodule OptimalSystemAgent.Verification.Tools.VerifyLoop.Prompt do
  @moduledoc """
  Dynamic prompt for `verify_loop`.
  """

  alias OptimalSystemAgent.Verification.Tools.VerifyLoop.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    """
    Spawn an autonomous verification loop that runs your test command,
    diagnoses failures with the LLM, applies fixes, and re-tests —
    up to max_iterations times. Returns the loop_id immediately.

    Use when you want to autonomously validate your work without manual
    intervention. The loop runs asynchronously so you can continue other
    work while verification proceeds.

    - `test_command` exit code 0 = pass, non-zero = fail
    - Max iterations: #{Constants.min_iterations()}–#{Constants.max_iterations()} (default: #{Constants.default_max_iterations()})
    - Returns a `loop_id` you can use to monitor or steer the loop
    """
  end
end
