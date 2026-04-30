defmodule OptimalSystemAgent.Tools.Builtins.CodeSandbox do
  @moduledoc """
  Execute code in an isolated Docker sandbox.

  Supports Python, JavaScript/Node, Go, Elixir, Ruby, and Rust.
  Each execution runs in an ephemeral container with strict resource limits:
  no network, read-only filesystem, capped memory/CPU, and no privilege escalation.

  When Docker is unavailable, falls back to unsandboxed execution for Elixir
  (via Code.eval_string in a Task) and for Python/JS (via System.cmd).
  Fallback output is prefixed with [UNSANDBOXED] as a safety warning.
  """

  @behaviour MiosaTools.Behaviour

  require Logger

  @supported_languages ~w(python javascript go elixir ruby rust)

  @language_images %{
    "python" => "python:3.12-slim",
    "javascript" => "node:22-slim",
    "go" => "golang:1.23-alpine",
    "elixir" => "elixir:1.18-slim",
    "ruby" => "ruby:3.3-slim",
    "rust" => "rust:1.77-slim"
  }

  @language_filenames %{
    "python" => "script.py",
    "javascript" => "script.js",
    "go" => "script.go",
    "elixir" => "script.exs",
    "ruby" => "script.rb",
    "rust" => "script.rs"
  }

  @language_commands %{
    "python" => "python3 /code/script.py",
    "javascript" => "node /code/script.js",
    "go" => "cd /code && go run script.go",
    "elixir" => "elixir /code/script.exs",
    "ruby" => "ruby /code/script.rb",
    "rust" => "cd /code && rustc script.rs -o /tmp/out && /tmp/out"
  }

  @max_timeout 60
  @default_timeout 30
  @max_output_bytes 100_000

  # -- Behaviour callbacks --

  @impl true
  def name, do: "code_sandbox"

  @impl true
  def description do
    "Execute code in an isolated sandbox. Supports Python, JavaScript/Node, Go, Elixir, Ruby, Rust. " <>
      "Sandboxed from host system for safety."
  end

  @impl true
  def safety, do: :write_safe

  @impl true
  def available? do
    docker_available?() or
      Application.get_env(:optimal_system_agent, :code_sandbox_fallback_enabled, false)
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "language" => %{
          "type" => "string",
          "enum" => @supported_languages,
          "description" => "Programming language: python, javascript, go, elixir, ruby, or rust"
        },
        "code" => %{
          "type" => "string",
          "description" => "Source code to execute"
        },
        "timeout" => %{
          "type" => "integer",
          "description" => "Maximum execution time in seconds (default 30, max 60)"
        },
        "stdin" => %{
          "type" => "string",
          "description" => "Optional input to provide via stdin"
        }
      },
      "required" => ["language", "code"]
    }
  end

  @impl true
  def execute(args) do
    with {:ok, language} <- validate_language(args),
         {:ok, code} <- validate_code(args),
         timeout <- resolve_timeout(args),
         stdin <- Map.get(args, "stdin") do
      if docker_available?() do
        execute_docker(language, code, timeout, stdin)
      else
        execute_fallback(language, code, timeout, stdin)
      end
    end
  end

  # -- Validation --

  defp validate_language(%{"language" => lang}) when lang in @supported_languages, do: {:ok, lang}

  defp validate_language(%{"language" => lang}),
    do:
      {:error,
       "Unsupported language: #{lang}. Supported: #{Enum.join(@supported_languages, ", ")}"}

  defp validate_language(_), do: {:error, "Missing required parameter: language"}

  defp validate_code(%{"code" => code}) when is_binary(code) and byte_size(code) > 0,
    do: {:ok, code}

  defp validate_code(%{"code" => ""}), do: {:error, "Code cannot be empty"}
  defp validate_code(%{"code" => _}), do: {:error, "Code must be a string"}
  defp validate_code(_), do: {:error, "Missing required parameter: code"}

  @doc false
  def resolve_timeout(%{"timeout" => t}) when is_integer(t) and t > 0, do: min(t, @max_timeout)
  def resolve_timeout(%{"timeout" => t}) when is_integer(t), do: @default_timeout
  def resolve_timeout(_), do: @default_timeout

  # -- Docker execution --

  defp execute_docker(language, code, timeout, stdin) do
    # Write code to a temp file — NEVER interpolate code into shell args
    tmp_dir = create_temp_dir()

    try do
      filename = @language_filenames[language]

      if is_nil(filename) do
        {:error, "Unsupported language: #{language}"}
      else
        code_path = Path.join(tmp_dir, filename)
        File.write!(code_path, code)

        image = @language_images[language]
        run_cmd = @language_commands[language]

        docker_args = build_docker_args(image, run_cmd, tmp_dir, timeout, stdin)

        Logger.debug("[CodeSandbox] Running #{language} in Docker (timeout=#{timeout}s)")

        # Use System.cmd to avoid shell injection — args are passed as a list
        timeout_ms = (timeout + 5) * 1_000

        task =
          Task.async(fn ->
            System.cmd("docker", docker_args, stderr_to_stdout: true, into: "")
          end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, exit_code}} ->
            format_result(output, exit_code)

          nil ->
            {:error, "Execution timed out after #{timeout}s"}
        end
      end
    after
      cleanup_temp_dir(tmp_dir)
    end
  end

  @doc false
  def build_docker_args(image, run_cmd, code_dir, _timeout, stdin) do
    base_args = [
      "run",
      "--rm",
      "--network=none",
      "--memory=256m",
      "--cpus=0.5",
      "--read-only",
      "--tmpfs",
      "/tmp:size=64m",
      "--security-opt=no-new-privileges",
      "-v",
      "#{code_dir}:/code:ro",
      image,
      "sh",
      "-c",
      run_cmd
    ]

    if stdin && stdin != "" do
      # Pipe stdin via echo through sh
      stdin_cmd = "echo #{shell_escape(stdin)} | #{run_cmd}"
      List.replace_at(base_args, -1, stdin_cmd)
    else
      base_args
    end
  end

  # -- Fallback execution (no Docker) --

  defp execute_fallback("elixir", code, timeout, _stdin) do
    if not Application.get_env(:optimal_system_agent, :code_sandbox_fallback_enabled, false) do
      {:error,
       "[UNSANDBOXED] Elixir fallback is disabled. Set :code_sandbox_fallback_enabled to true or install Docker."}
    else
      execute_elixir_fallback(code, timeout)
    end
  end

  defp execute_fallback("python", code, timeout, stdin) do
    if Application.get_env(:optimal_system_agent, :code_sandbox_fallback_enabled, false) do
      execute_fallback_cmd("python3", code, "py", timeout, stdin)
    else
      {:error,
       "[UNSANDBOXED] Python fallback is disabled. Set :code_sandbox_fallback_enabled to true or install Docker."}
    end
  end

  defp execute_fallback("javascript", code, timeout, stdin) do
    if Application.get_env(:optimal_system_agent, :code_sandbox_fallback_enabled, false) do
      execute_fallback_cmd("node", code, "js", timeout, stdin)
    else
      {:error,
       "[UNSANDBOXED] JavaScript fallback is disabled. Set :code_sandbox_fallback_enabled to true or install Docker."}
    end
  end

  defp execute_fallback(language, _code, _timeout, _stdin) do
    {:error,
     "[UNSANDBOXED] Fallback execution not supported for #{language}. Install Docker for full language support."}
  end

  defp execute_elixir_fallback(code, timeout) do
    Logger.info("[CodeSandbox] Fallback: running Elixir unsandboxed via Code.eval_string")

    timeout_ms = timeout * 1_000

    task =
      Task.async(fn ->
        try do
          {:ok, string_io} = StringIO.open("")
          original_gl = Process.group_leader()
          Process.group_leader(self(), string_io)

          try do
            {result, _binding} = Code.eval_string(code)
            Process.group_leader(self(), original_gl)

            {_input, captured} = StringIO.contents(string_io)
            StringIO.close(string_io)

            output =
              case {String.trim(captured), inspect(result)} do
                {io_out, "nil"} -> io_out
                {"", result_str} -> result_str
                {io_out, result_str} -> io_out <> "\n" <> result_str
              end

            {:ok, "[UNSANDBOXED] #{String.trim(output)}"}
          after
            Process.group_leader(self(), original_gl)
          end
        rescue
          e -> {:error, "[UNSANDBOXED] Error: #{Exception.message(e)}"}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "[UNSANDBOXED] Execution timed out after #{timeout}s"}
    end
  end

  defp execute_fallback_cmd(executable, code, ext, timeout, stdin) do
    case System.find_executable(executable) do
      nil ->
        {:error, "[UNSANDBOXED] #{executable} not found on system"}

      exe_path ->
        tmp_dir = create_temp_dir()

        try do
          code_path = Path.join(tmp_dir, "script.#{ext}")
          File.write!(code_path, code)

          Logger.info("[CodeSandbox] Fallback: running #{executable} unsandboxed")

          timeout_ms = timeout * 1_000
          opts = [stderr_to_stdout: true, cd: tmp_dir]

          opts =
            if stdin && stdin != "" do
              Keyword.put(opts, :stdin, stdin)
            else
              opts
            end

          task =
            Task.async(fn ->
              System.cmd(exe_path, [code_path], opts)
            end)

          case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
            {:ok, {output, exit_code}} ->
              format_result("[UNSANDBOXED] " <> output, exit_code)

            nil ->
              {:error, "[UNSANDBOXED] Execution timed out after #{timeout}s"}
          end
        after
          cleanup_temp_dir(tmp_dir)
        end
    end
  end

  # -- Helpers --

  @doc false
  def docker_available? do
    System.find_executable("docker") != nil
  end

  @doc false
  def language_image(language), do: Map.get(@language_images, language)

  @doc false
  def supported_languages, do: @supported_languages

  defp create_temp_dir do
    id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "osa_sandbox_#{id}")
    File.mkdir_p!(dir)
    dir
  end

  defp cleanup_temp_dir(dir) do
    File.rm_rf(dir)
  rescue
    _ -> :ok
  end

  defp format_result(output, 0) do
    {:ok, truncate(output)}
  end

  defp format_result(output, exit_code) do
    {:error, "Exit #{exit_code}:\n#{truncate(output)}"}
  end

  defp truncate(output) do
    if byte_size(output) > @max_output_bytes do
      String.slice(output, 0, @max_output_bytes) <> "\n[output truncated at 100KB]"
    else
      output
    end
  end

  # Escape a string for safe use in a shell single-quote context.
  # Wraps in single quotes and escapes any embedded single quotes.
  defp shell_escape(str) do
    escaped = String.replace(str, "'", "'\\''")
    "'#{escaped}'"
  end
end
