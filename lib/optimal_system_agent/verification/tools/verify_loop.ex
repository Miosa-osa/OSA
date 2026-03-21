defmodule OptimalSystemAgent.Verification.Tools.VerifyLoop do
  @moduledoc """
  Tool: `verify_loop` — spawn a verification loop on the current task.

  Allows agents to autonomously trigger the write → test → diagnose → fix →
  re-test cycle against their own work. The loop runs asynchronously; this
  tool returns immediately with the loop_id so the agent can poll or continue
  other work.

  ## Parameters

    - `test_command` (required) — shell command to run as the verification gate.
      Exit code 0 = pass, non-zero = fail.
    - `max_iterations` (optional) — max fail/fix cycles before escalating to
      human. Default: 5.
    - `task_id` (optional) — identifier of the task being verified. Injected
      automatically from `__session_id__` when omitted.

  ## Returns

  A JSON string with:

  ```json
  {
    "loop_id": "vloop_abc123",
    "status": "started",
    "test_command": "mix test",
    "max_iterations": 5
  }
  ```

  Use `loop_id` to call `steer_verify_loop` (future tool) or monitor progress
  via events.
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  alias OptimalSystemAgent.Verification.Loop

  @impl true
  def name, do: "verify_loop"

  @impl true
  def description do
    "Spawn an autonomous verification loop that runs your test command, " <>
      "diagnoses failures with the LLM, applies fixes, and re-tests — " <>
      "up to max_iterations times. Returns the loop_id immediately. " <>
      "Use when you want to autonomously validate your work without manual intervention."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["test_command"],
      "properties" => %{
        "test_command" => %{
          "type" => "string",
          "description" =>
            "Shell command to run as the verification gate. " <>
              "Exit code 0 = pass, non-zero = fail. " <>
              "Examples: 'mix test', 'npm test', 'pytest', 'go test ./...'."
        },
        "max_iterations" => %{
          "type" => "integer",
          "description" =>
            "Maximum number of fail/fix/re-test cycles before escalating to human. " <>
              "Default: 5. Must be between 1 and 20.",
          "default" => 5,
          "minimum" => 1,
          "maximum" => 20
        },
        "task_id" => %{
          "type" => "string",
          "description" =>
            "Identifier of the task being verified. " <>
              "Defaults to the current session ID if omitted."
        }
      }
    }
  end

  @impl true
  def safety, do: :write_safe

  @impl true
  def execute(params) do
    test_command = Map.get(params, "test_command", "")
    max_iterations = Map.get(params, "max_iterations", 5)
    session_id = Map.get(params, "__session_id__", "unknown")
    task_id = Map.get(params, "task_id", session_id)

    if String.trim(test_command) == "" do
      {:ok, ~s({"error": "test_command is required and must not be blank"})}
    else
      clamped_iterations = max_iterations |> max(1) |> min(20)

      opts = [
        test_command: test_command,
        task_id: task_id,
        max_iterations: clamped_iterations
      ]

      case DynamicSupervisor.start_child(
             OptimalSystemAgent.Verification.LoopSupervisor,
             {Loop, opts}
           ) do
        {:ok, _pid} ->
          # Retrieve the loop_id that was generated inside Loop.init/1.
          # The loop registers itself in SessionRegistry under "vloop:{loop_id}";
          # we can discover it by querying the registry for the task_id pattern.
          loop_id = discover_loop_id(task_id, test_command)

          result = %{
            "loop_id" => loop_id,
            "status" => "started",
            "test_command" => test_command,
            "max_iterations" => clamped_iterations,
            "task_id" => task_id
          }

          {:ok, Jason.encode!(result)}

        {:error, reason} ->
          error_msg = "Failed to start verification loop: #{inspect(reason)}"
          Logger.warning("[verify_loop tool] #{error_msg}")
          {:ok, Jason.encode!(%{"error" => error_msg})}
      end
    end
  end

  # --- Private ---

  # The Loop registers under "vloop:{loop_id}" in SessionRegistry.
  # Since we don't have the loop_id before start_link completes, we discover
  # it by finding the most recently registered "vloop:" entry in the registry.
  # Falls back to a placeholder if the registry lookup races.
  defp discover_loop_id(_task_id, _test_command) do
    try do
      matches =
        Registry.select(OptimalSystemAgent.SessionRegistry, [
          {{:"$1", :_, :_}, [{:is_binary, :"$1"}], [:"$1"]}
        ])
        |> Enum.filter(&String.starts_with?(&1, "vloop:"))
        |> Enum.sort(:desc)

      case matches do
        [latest | _] -> String.replace_prefix(latest, "vloop:", "")
        [] -> "unknown"
      end
    rescue
      _ -> "unknown"
    end
  end
end
