defmodule OptimalSystemAgent.Bench.Workspace do
  @moduledoc """
  Materialises a task's scratch copy of its fixture repo and applies the task's
  setup ops. Every run gets a fresh directory, so a task can never see another
  task's (or another attempt's) edits.

  ## Setup ops

    * `{:write, path, content}` - create or overwrite a file.
    * `{:replace, path, from, to}` - replace text that must occur exactly once.
    * `{:delete, path}` - remove a file.
    * `{:noise, dir, count, file_template, content_template}` - `count`
      generated files under `dir`; `{{n}}` in either template is the file
      number. Models `deps/` and `_build/` trees an unscoped search walks.
    * `{:large_file, path, lines, line_template, specials}` - a `lines`-long
      file of `line_template` (`{{n}}` = line number) with `specials`, a map of
      line number to literal text, spliced in.
    * `{:git_init}` / `{:git_commit, message}` - a repository with history.
      Commits stage everything and use a fixed identity and date.

  All paths are relative to the workspace root and may not escape it.
  """

  @doc """
  Copy `fixture_dir` to a fresh directory under `work_root` and apply `setup`.
  Returns the directory.
  """
  @spec prepare(Path.t(), Path.t(), String.t(), list()) :: {:ok, Path.t()} | {:error, String.t()}
  def prepare(fixture_dir, work_root, name, setup) do
    dir = Path.join(work_root, "#{name}-#{System.unique_integer([:positive])}")

    with :ok <- copy_fixture(fixture_dir, dir),
         :ok <- apply_ops(dir, setup) do
      {:ok, dir}
    end
  end

  defp copy_fixture(fixture_dir, dir) do
    cond do
      not File.dir?(fixture_dir) ->
        {:error, "fixture not found: #{fixture_dir}"}

      true ->
        File.mkdir_p!(Path.dirname(dir))

        case File.cp_r(fixture_dir, dir) do
          {:ok, _} -> :ok
          {:error, reason, file} -> {:error, "copy failed at #{file}: #{inspect(reason)}"}
        end
    end
  end

  @doc "Apply setup ops in order; the first failure stops the setup."
  @spec apply_ops(Path.t(), list()) :: :ok | {:error, String.t()}
  def apply_ops(dir, ops) do
    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case apply_op(dir, op) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "setup #{inspect(elem(op, 0))}: #{reason}"}}
      end
    end)
  end

  defp apply_op(dir, {:write, rel, content}) do
    with {:ok, path} <- resolve(dir, rel) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      :ok
    end
  end

  defp apply_op(dir, {:replace, rel, from, to}) do
    with {:ok, path} <- resolve(dir, rel),
         {:ok, content} <- read(path) do
      case count(content, from) do
        1 -> File.write!(path, String.replace(content, from, to))
        n -> {:error, "#{rel}: expected exactly one match for #{inspect(from)}, found #{n}"}
      end
      |> ok()
    end
  end

  defp apply_op(dir, {:delete, rel}) do
    with {:ok, path} <- resolve(dir, rel) do
      File.rm_rf!(path)
      :ok
    end
  end

  defp apply_op(dir, {:noise, rel_dir, n, file_template, content_template}) do
    with {:ok, base} <- resolve(dir, rel_dir) do
      Enum.each(1..n, fn i ->
        path = Path.join(base, fill(file_template, i))
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, fill(content_template, i))
      end)

      :ok
    end
  end

  defp apply_op(dir, {:large_file, rel, lines, line_template, specials}) do
    with {:ok, path} <- resolve(dir, rel) do
      File.mkdir_p!(Path.dirname(path))

      body =
        Enum.map(1..lines, fn i -> [Map.get(specials, i) || fill(line_template, i), "\n"] end)

      File.write!(path, body)
      :ok
    end
  end

  defp apply_op(dir, {:git_init}) do
    git(dir, ["init", "--quiet", "--initial-branch=main"])
  end

  defp apply_op(dir, {:git_commit, message}) do
    with :ok <- git(dir, ["add", "--all"]) do
      git(dir, [
        "-c",
        "user.name=bench",
        "-c",
        "user.email=bench@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--quiet",
        "--allow-empty",
        "--date=2026-01-01T00:00:00Z",
        "-m",
        message
      ])
    end
  end

  defp apply_op(_dir, op), do: {:error, "unknown setup op #{inspect(op)}"}

  defp git(dir, args) do
    env = [{"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

    case OptimalSystemAgent.Git.cmd(args, cd: dir, env: env, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, code} ->
        {:error, "git #{Enum.join(args, " ")} exited #{code}: #{String.slice(out, 0, 200)}"}
    end
  rescue
    e -> {:error, "git unavailable: #{Exception.message(e)}"}
  end

  @doc "Resolve `rel` inside `dir`, refusing anything that escapes it."
  @spec resolve(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def resolve(dir, rel) do
    root = Path.expand(dir)
    path = Path.expand(rel, root)

    if path == root or String.starts_with?(path, root <> "/"),
      do: {:ok, path},
      else: {:error, "path escapes the workspace: #{rel}"}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  defp count(content, from), do: length(String.split(content, from)) - 1

  defp fill(template, i), do: String.replace(template, "{{n}}", Integer.to_string(i))

  defp ok(:ok), do: :ok
  defp ok({:error, _} = e), do: e
end
