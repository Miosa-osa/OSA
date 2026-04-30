defmodule OptimalSystemAgent.Verification.Tools.VerifyLoop.Handler do
  @moduledoc """
  Validation and execution logic for `verify_loop`.

    * `validate/2`  — type-check input shape
    * `execute/2`   — spawn the Loop process, return loop_id
  """

  require Logger

  alias OptimalSystemAgent.Verification.Loop
  alias OptimalSystemAgent.Verification.Tools.VerifyLoop.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"test_command" => cmd} = input, _ctx) when is_binary(cmd), do: {:ok, input}

  def validate(%{"test_command" => _}, _ctx),
    do: {:error, "test_command must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: test_command", -32_602}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"test_command" => test_command} = params, _ctx) do
    if String.trim(test_command) == "" do
      {:ok, ~s({"error": "test_command is required and must not be blank"})}
    else
      max_iterations = Map.get(params, "max_iterations", Constants.default_max_iterations())
      session_id = Map.get(params, "__session_id__", "unknown")
      task_id = Map.get(params, "task_id", session_id)

      clamped =
        max_iterations
        |> max(Constants.min_iterations())
        |> min(Constants.max_iterations())

      opts = [
        test_command: test_command,
        task_id: task_id,
        max_iterations: clamped
      ]

      case DynamicSupervisor.start_child(
             OptimalSystemAgent.Verification.LoopSupervisor,
             {Loop, opts}
           ) do
        {:ok, _pid} ->
          loop_id = discover_loop_id()

          result = %{
            "loop_id" => loop_id,
            "status" => "started",
            "test_command" => test_command,
            "max_iterations" => clamped,
            "task_id" => task_id
          }

          {:ok, Jason.encode!(result)}

        {:error, reason} ->
          error_msg = "Failed to start verification loop: #{inspect(reason)}"
          Logger.warning("[verify_loop handler] #{error_msg}")
          {:ok, Jason.encode!(%{"error" => error_msg})}
      end
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  # Discover the most recently registered "vloop:" key in the SessionRegistry.
  # Falls back to "unknown" on race or registry absence.
  defp discover_loop_id do
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
