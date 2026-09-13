defmodule OptimalSystemAgent.Tools.Builtins.REPL.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `repl`.

    * `validate/2`          — type checks input shape
    * `check_permissions/2` — language allowlist check
    * `execute/2`           — run code in the requested language runtime
  """

  alias OptimalSystemAgent.Tools.Builtins.REPL.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"code" => code} = input, _ctx) when is_binary(code), do: {:ok, input}

  def validate(%{"code" => _}, _ctx),
    do: {:error, "code must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: code", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"language" => lang} = _input, _ctx)
      when lang not in ["python", "elixir", "node"] do
    {:deny,
     "Access denied: unsupported language #{inspect(lang)}. Allowed: #{Enum.join(Constants.supported_languages(), ", ")}"}
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"code" => code} = args, _ctx) do
    language = Map.get(args, "language", "python")

    {cmd, cmd_args} = build_command(language, code)

    if cmd == nil do
      {:error, "Unsupported language: #{language}. Use python, elixir, or node."}
    else
      run_command(cmd, cmd_args, language)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp build_command("python", code), do: {"python3", ["-c", code]}
  defp build_command("elixir", code), do: {"elixir", ["-e", code]}
  defp build_command("node", code), do: {"node", ["-e", code]}
  defp build_command(_, _code), do: {nil, nil}

  defp run_command(cmd, args, language) do
    timeout =
      Application.get_env(:optimal_system_agent, :repl_timeout_ms, Constants.default_timeout_ms())

    try do
      case System.cmd(cmd, args,
             stderr_to_stdout: true,
             env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
             timeout: timeout
           ) do
        {output, 0} ->
          {:ok, format_output(output, language)}

        {output, exit_code} ->
          {:ok, "Exit code: #{exit_code}\n\n#{format_output(output, language)}"}
      end
    rescue
      e in ErlangError ->
        case e do
          %ErlangError{original: :enoent} ->
            {:error, "#{language} runtime not found. Install #{cmd} to use the REPL."}

          _ ->
            {:error, "REPL error: #{Exception.message(e)}"}
        end

      e ->
        {:error, "REPL error: #{Exception.message(e)}"}
    catch
      :exit, {:timeout, _} ->
        {:error, "REPL execution timed out after #{div(timeout, 1000)}s"}
    end
  end

  defp format_output(output, _language) do
    output = String.trim(output)
    if output == "", do: "(no output)", else: output
  end
end
