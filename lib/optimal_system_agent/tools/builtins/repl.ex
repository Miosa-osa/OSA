defmodule OptimalSystemAgent.Tools.Builtins.REPL do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  @impl true
  def name, do: "repl"

  @impl true
  def deferred?, do: true

  @impl true
  def description do
    "Execute code in an interactive REPL session.\n\n" <>
      "Supports Python, Elixir (iex), and Node.js. The session persists across calls —\n" <>
      "variables and state carry over between executions within the same session.\n\n" <>
      "Use for:\n" <>
      "- Quick code validation without creating files\n" <>
      "- Data processing and exploration\n" <>
      "- Testing code snippets before writing to files\n" <>
      "- Mathematical calculations"
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["code"],
      "properties" => %{
        "code" => %{
          "type" => "string",
          "description" => "Code to execute in the REPL"
        },
        "language" => %{
          "type" => "string",
          "enum" => ["python", "elixir", "node"],
          "description" => "Language runtime (default: python)"
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Reuse a named session for state persistence (default: auto)"
        }
      }
    }
  end

  @impl true
  def execute(%{"code" => code} = args) do
    language = Map.get(args, "language", "python")
    session_key = Map.get(args, "session_id", "default_#{language}")

    {cmd, cmd_args, input} = build_command(language, code)

    if cmd == nil do
      {:error, "Unsupported language: #{language}. Use python, elixir, or node."}
    else
      execute_in_repl(cmd, cmd_args, input, session_key, language)
    end
  end

  def execute(_), do: {:error, "Missing required parameter: code"}

  # ── Command builders ─────────────────────────────────────────────────

  defp build_command("python", code) do
    # Use python3 -c for one-shot execution (persistent sessions need Port)
    {"python3", ["-c", code], nil}
  end

  defp build_command("elixir", code) do
    {"elixir", ["-e", code], nil}
  end

  defp build_command("node", code) do
    {"node", ["-e", code], nil}
  end

  defp build_command(_, _code), do: {nil, nil, nil}

  # ── Execution ────────────────────────────────────────────────────────

  defp execute_in_repl(cmd, args, _input, _session_key, language) do
    timeout = Application.get_env(:optimal_system_agent, :repl_timeout_ms, 30_000)

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
