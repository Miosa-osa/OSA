defmodule OptimalSystemAgent.Tools.Builtins.LatexCompile.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `latex_compile`.

  Mirrors the layout of `ShellExecute.Handler`:
    * `validate/2`          — type-checks input shape (cheap)
    * `check_permissions/2` — permission decision (writes only under ~/.osa)
    * `execute/2`           — materialise source, run the engine, parse the log

  Execution shells out to a LaTeX engine via a `Port` (not `System.cmd`) so the
  OS process can be killed on timeout instead of leaking an orphaned child.
  """

  require Logger

  alias OptimalSystemAgent.Tools.Builtins.LatexCompile.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(input, _ctx) when is_map(input) do
    with :ok <- validate_source(input),
         :ok <- validate_engine(input),
         :ok <- validate_optional_string(input, "output_dir"),
         :ok <- validate_optional_string(input, "jobname") do
      {:ok, input}
    end
  end

  def validate(_input, _ctx),
    do: {:error, "Input must be a map", -32_602}

  defp validate_source(input) do
    content = input["tex_content"]
    path = input["tex_path"]

    cond do
      is_binary(content) and String.trim(content) != "" ->
        :ok

      is_binary(path) and String.trim(path) != "" ->
        :ok

      not is_nil(content) and not is_binary(content) ->
        {:error, "tex_content must be a string", -32_602}

      not is_nil(path) and not is_binary(path) ->
        {:error, "tex_path must be a string", -32_602}

      true ->
        {:error, "Provide either tex_content (LaTeX source) or tex_path (a .tex file)", -32_602}
    end
  end

  defp validate_engine(input) do
    case input["engine"] do
      nil ->
        :ok

      engine when is_binary(engine) ->
        if engine in Constants.engines() do
          :ok
        else
          {:error, "engine must be one of: #{Enum.join(Constants.engines(), ", ")}", -32_602}
        end

      _ ->
        {:error, "engine must be a string", -32_602}
    end
  end

  defp validate_optional_string(input, key) do
    case input[key] do
      nil -> :ok
      v when is_binary(v) -> :ok
      _ -> {:error, "#{key} must be a string", -32_602}
    end
  end

  # ── Stage 2: Permission check ─────────────────────────────────────────
  #
  # latex_compile only ever writes under a scratch output directory (default
  # ~/.osa/latex) and reads a source file — no destructive OS surface — so it
  # is allowed outright.

  @spec check_permissions(map(), UseContext.t()) :: {:allow, map()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, map()}
  def execute(input, _ctx) do
    engine = input["engine"] || Constants.default_engine()
    jobname = sanitize_jobname(input["jobname"])
    output_dir = resolve_output_dir(input["output_dir"])
    File.mkdir_p!(output_dir)

    with {:ok, tex_file, compile_cwd, eff_jobname} <-
           materialize_source(input, output_dir, jobname),
         {:ok, binary} <- resolve_binary(engine) do
      compile(engine, binary, tex_file, compile_cwd, output_dir, eff_jobname)
    else
      {:error, message} ->
        {:ok, error_result(engine, output_dir, jobname, [message], message)}
    end
  rescue
    e ->
      msg = "latex_compile failed: #{Exception.message(e)}"
      Logger.error("[latex_compile] #{msg}")

      {:ok,
       error_result(
         input["engine"] || Constants.default_engine(),
         fallback_dir(),
         Constants.default_jobname(),
         [msg],
         msg
       )}
  end

  # ── Source materialisation ────────────────────────────────────────────

  defp materialize_source(%{"tex_content" => content}, output_dir, jobname)
       when is_binary(content) and content != "" do
    dest = Path.join(output_dir, jobname <> ".tex")

    case File.write(dest, content) do
      :ok -> {:ok, jobname <> ".tex", output_dir, jobname}
      {:error, reason} -> {:error, "could not write tex_content: #{:file.format_error(reason)}"}
    end
  end

  defp materialize_source(%{"tex_path" => path}, _output_dir, _jobname) when is_binary(path) do
    src = Path.expand(path)

    cond do
      not File.exists?(src) ->
        {:error, "tex_path does not exist: #{src}"}

      not File.regular?(src) ->
        {:error, "tex_path is not a regular file: #{src}"}

      true ->
        {:ok, Path.basename(src), Path.dirname(src), Path.rootname(Path.basename(src))}
    end
  end

  defp materialize_source(_input, _output_dir, _jobname),
    do: {:error, "Provide either tex_content or tex_path"}

  # ── Engine resolution ─────────────────────────────────────────────────

  defp resolve_binary(engine) do
    local = Path.join(Path.expand(Constants.local_bin_dir()), engine)

    cond do
      is_binary(System.find_executable(engine)) ->
        {:ok, System.find_executable(engine)}

      File.exists?(local) ->
        {:ok, local}

      true ->
        {:error, "LaTeX engine '#{engine}' not found on PATH or in #{Constants.local_bin_dir()}"}
    end
  end

  # ── Compilation ───────────────────────────────────────────────────────

  defp compile(engine, binary, tex_file, compile_cwd, output_dir, jobname) do
    log_path = Path.join(output_dir, jobname <> ".log")

    result =
      case engine do
        "pdflatex" ->
          # Two passes so cross-references / ToC resolve.
          first = run_binary(binary, engine_args(engine, tex_file, output_dir), compile_cwd)

          case first do
            {:ok, _status, out1} ->
              case run_binary(binary, engine_args(engine, tex_file, output_dir), compile_cwd) do
                {:ok, status, out2} -> {:ok, status, out1 <> out2}
                other -> other
              end

            other ->
              other
          end

        _ ->
          run_binary(binary, engine_args(engine, tex_file, output_dir), compile_cwd)
      end

    finalize(engine, output_dir, jobname, log_path, result)
  end

  defp engine_args("tectonic", tex_file, output_dir),
    do: [tex_file, "--outdir", output_dir, "--keep-logs"]

  defp engine_args("latexmk", tex_file, output_dir),
    do: ["-pdf", "-interaction=nonstopmode", "-outdir=" <> output_dir, tex_file]

  defp engine_args("pdflatex", tex_file, output_dir),
    do: ["-interaction=nonstopmode", "-output-directory=" <> output_dir, tex_file]

  defp finalize(engine, output_dir, _jobname, log_path, {:timeout, output}) do
    File.write(log_path, output)

    errors =
      ["Compilation timed out after #{Constants.default_timeout_ms()} ms" | parse_errors(output)]

    build_result("error", nil, log_path, errors, engine, output_dir)
    |> wrap()
  end

  defp finalize(engine, output_dir, jobname, log_path, {:error, message}) do
    File.write(log_path, message)
    {:ok, error_result(engine, output_dir, jobname, [message], message)}
  end

  defp finalize(engine, output_dir, jobname, log_path, {:ok, _status, output}) do
    File.write(log_path, output)
    pdf_path = Path.join(output_dir, jobname <> ".pdf")
    errors = parse_errors(output)

    if pdf_present?(pdf_path) do
      build_result("ok", pdf_path, log_path, errors, engine, output_dir) |> wrap()
    else
      errors = if errors == [], do: ["No PDF was produced; see log for details"], else: errors
      build_result("error", nil, log_path, errors, engine, output_dir) |> wrap()
    end
  end

  defp pdf_present?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp build_result(status, pdf_path, log_path, errors, engine, output_dir) do
    %{
      status: status,
      pdf_path: pdf_path,
      log_path: log_path,
      errors: Enum.take(errors, Constants.max_errors()),
      engine: engine,
      output_dir: output_dir
    }
  end

  defp error_result(engine, output_dir, jobname, errors, log_message) do
    log_path = Path.join(output_dir, jobname <> ".log")
    File.write(log_path, log_message)
    build_result("error", nil, log_path, errors, engine, output_dir)
  end

  defp wrap(result), do: {:ok, result}

  # ── Port-based process runner ─────────────────────────────────────────
  #
  # Spawn the engine directly (no shell) so a hostile jobname can't inject
  # shell metacharacters, and so the OS process is killable on timeout.

  defp run_binary(binary, args, cwd) do
    timeout_ms = Constants.default_timeout_ms()

    port =
      Port.open(
        {:spawn_executable, binary},
        [:binary, :exit_status, :hide, :stderr_to_stdout, {:args, args}, {:cd, cwd}]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, os_pid, deadline, [])
  rescue
    e -> {:error, "engine execution error: #{Exception.message(e)}"}
  end

  defp collect(port, os_pid, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, [data | acc])

      {^port, {:exit_status, status}} ->
        {:ok, status, IO.iodata_to_binary(Enum.reverse(acc))}
    after
      remaining ->
        kill(os_pid)
        close(port)
        {:timeout, IO.iodata_to_binary(Enum.reverse(acc))}
    end
  end

  defp kill(nil), do: :ok

  defp kill(os_pid) do
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── Log parsing ───────────────────────────────────────────────────────
  #
  # LaTeX/TeX report fatal errors as a line starting with `! `, usually followed
  # (within a couple of lines) by a `l.<n>` line pointing at the offending
  # source line. tectonic additionally emits `error:` lines. Collect both.

  defp parse_errors(output) when is_binary(output) do
    lines = String.split(output, ~r/\r?\n/)

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, idx} ->
      cond do
        String.starts_with?(line, "! ") ->
          [String.trim_trailing(line) | line_reference(lines, idx)]

        Regex.match?(~r/^\s*error:/, line) ->
          [String.trim(line)]

        true ->
          []
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_errors(_), do: []

  defp line_reference(lines, idx) do
    lines
    |> Enum.drop(idx + 1)
    |> Enum.take(3)
    |> Enum.find(&Regex.match?(~r/^l\.\d+/, &1))
    |> case do
      nil -> []
      ref -> [String.trim_trailing(ref)]
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp sanitize_jobname(name) when is_binary(name) do
    cleaned =
      name
      |> String.trim()
      |> String.replace(~r/[^A-Za-z0-9_\-]/, "_")

    if cleaned == "", do: Constants.default_jobname(), else: cleaned
  end

  defp sanitize_jobname(_), do: Constants.default_jobname()

  defp resolve_output_dir(dir) when is_binary(dir) and dir != "", do: Path.expand(dir)
  defp resolve_output_dir(_), do: fresh_output_dir()

  defp fresh_output_dir do
    stamp = System.system_time(:millisecond)
    rand = :rand.uniform(0xFFFFFF)
    Path.join(Path.expand(Constants.base_output_dir()), "#{stamp}-#{rand}")
  end

  defp fallback_dir, do: Path.expand(Constants.base_output_dir())
end
