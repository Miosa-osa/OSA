defmodule OptimalSystemAgent.Bench.Check do
  @moduledoc """
  Deterministic pass/fail for a finished task. A task passes when every one of
  its check ops passes.

  ## Check ops

  Paths are relative to the workspace. A `pattern` is a literal string
  (substring match) or a `Regex`.

    * `{:file_contains, path, pattern}` / `{:file_lacks, path, pattern}`
    * `{:file_exists, path}` / `{:file_absent, path}`
    * `{:file_unchanged, path}` - byte-identical to the file right after setup.
    * `{:last_line, path, text}` - the last non-empty line, trimmed.
    * `{:json_equals, path, keys, value}` - the value at `keys` (a list) in the
      decoded JSON file.
    * `{:json_unchanged_except, path, keys_list}` - the decoded JSON equals its
      post-setup value everywhere except the listed key paths.
    * `{:tree_lacks, glob, pattern}` - no file matching `glob` contains it.
    * `{:tree_count, glob, pattern, n}` - exactly `n` matches across `glob`.
    * `{:answer_matches, pattern}` / `{:answer_lacks, pattern}` - the agent's
      final reply.
    * `{:tests_pass}` - `elixir scripts/run_tests.exs` exits 0.
    * `{:command, cmd, args}` - exits 0 in the workspace.
  """

  alias OptimalSystemAgent.Bench.Workspace

  @command_timeout_ms 120_000

  @type result :: %{op: String.t(), pass: boolean(), detail: String.t()}

  @doc """
  Record what the checks will later compare against (`:file_unchanged`,
  `:json_unchanged_except`). Called right after setup, before the agent runs.
  """
  @spec snapshot(Path.t(), list()) :: map()
  def snapshot(dir, checks) do
    checks
    |> Enum.flat_map(fn
      {:file_unchanged, rel} -> [rel]
      {:json_unchanged_except, rel, _} -> [rel]
      _ -> []
    end)
    |> Map.new(fn rel ->
      content =
        case Workspace.resolve(dir, rel) do
          {:ok, path} -> File.read(path) |> ok_or_nil()
          _ -> nil
        end

      {rel, content}
    end)
  end

  @doc "Run every check. Returns `{pass?, results}`."
  @spec run(list(), Path.t(), String.t() | nil, map()) :: {boolean(), [result()]}
  def run(checks, dir, answer, snapshot \\ %{}) do
    results = Enum.map(checks, &run_one(&1, dir, answer || "", snapshot))
    {Enum.all?(results, & &1.pass), results}
  end

  defp run_one(op, dir, answer, snapshot) do
    {pass, detail} =
      try do
        check(op, dir, answer, snapshot)
      rescue
        e -> {false, "check raised: #{Exception.message(e)}"}
      end

    %{op: describe(op), pass: pass, detail: detail}
  end

  defp check({:file_contains, rel, pattern}, dir, _answer, _snap) do
    with_file(dir, rel, fn content ->
      verdict(hit?(content, pattern), "#{rel} contains #{show(pattern)}")
    end)
  end

  defp check({:file_lacks, rel, pattern}, dir, _answer, _snap) do
    with_file(dir, rel, fn content ->
      verdict(not hit?(content, pattern), "#{rel} lacks #{show(pattern)}")
    end)
  end

  defp check({:file_exists, rel}, dir, _answer, _snap) do
    {:ok, path} = Workspace.resolve(dir, rel)
    verdict(File.exists?(path), "#{rel} exists")
  end

  defp check({:file_absent, rel}, dir, _answer, _snap) do
    {:ok, path} = Workspace.resolve(dir, rel)
    verdict(not File.exists?(path), "#{rel} is absent")
  end

  defp check({:file_unchanged, rel}, dir, _answer, snap) do
    with_file(dir, rel, fn content ->
      verdict(content == Map.get(snap, rel), "#{rel} unchanged")
    end)
  end

  defp check({:last_line, rel, text}, dir, _answer, _snap) do
    with_file(dir, rel, fn content ->
      last =
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> List.last()

      verdict(last == text, "last line of #{rel} is #{inspect(text)} (got #{inspect(last)})")
    end)
  end

  defp check({:json_equals, rel, keys, value}, dir, _answer, _snap) do
    with_json(dir, rel, fn data ->
      actual = get_in(data, keys)

      verdict(
        actual == value,
        "#{rel} #{Enum.join(keys, ".")} == #{inspect(value)} (got #{inspect(actual)})"
      )
    end)
  end

  defp check({:json_unchanged_except, rel, key_paths}, dir, _answer, snap) do
    with {:ok, before} <- decode(Map.get(snap, rel)) do
      with_json(dir, rel, fn data ->
        strip = fn map -> Enum.reduce(key_paths, map, &drop_path(&2, &1)) end

        verdict(
          strip.(data) == strip.(before),
          "#{rel} unchanged apart from #{inspect(key_paths)}"
        )
      end)
    else
      _ -> {false, "#{rel}: no post-setup snapshot to compare"}
    end
  end

  defp check({:tree_lacks, glob, pattern}, dir, _answer, _snap) do
    hits = tree_files(dir, glob) |> Enum.filter(fn {_rel, c} -> hit?(c, pattern) end)

    verdict(
      hits == [],
      "no #{glob} file contains #{show(pattern)}" <>
        if(hits == [],
          do: "",
          else: " (found in #{hits |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")})"
        )
    )
  end

  defp check({:tree_count, glob, pattern, n}, dir, _answer, _snap) do
    found =
      tree_files(dir, glob)
      |> Enum.map(fn {_rel, c} -> count(c, pattern) end)
      |> Enum.sum()

    verdict(found == n, "#{n} occurrence(s) of #{show(pattern)} in #{glob} (got #{found})")
  end

  defp check({:answer_matches, pattern}, _dir, answer, _snap) do
    verdict(hit?(answer, pattern), "answer matches #{show(pattern)}")
  end

  defp check({:answer_lacks, pattern}, _dir, answer, _snap) do
    verdict(not hit?(answer, pattern), "answer lacks #{show(pattern)}")
  end

  defp check({:tests_pass}, dir, _answer, _snap) do
    command(dir, "elixir", ["scripts/run_tests.exs"])
  end

  defp check({:command, cmd, args}, dir, _answer, _snap), do: command(dir, cmd, args)

  defp check(op, _dir, _answer, _snap), do: {false, "unknown check op #{inspect(op)}"}

  # ── helpers ──────────────────────────────────────────────────────────

  defp command(dir, cmd, args) do
    label = [cmd | args] |> Enum.join(" ") |> String.replace(~r/\s+/, " ") |> String.slice(0, 60)

    task =
      Task.async(fn ->
        System.cmd(cmd, args, cd: dir, stderr_to_stdout: true, env: [{"MIX_ENV", nil}])
      end)

    case Task.yield(task, @command_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} -> {true, "#{label} exited 0"}
      {:ok, {out, code}} -> {false, "#{label} exited #{code}: #{tail(out)}"}
      nil -> {false, "#{label} timed out"}
    end
  rescue
    e -> {false, "#{cmd} could not run: #{Exception.message(e)}"}
  end

  defp tree_files(dir, glob) do
    root = Path.expand(dir)

    root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
  end

  defp with_file(dir, rel, fun) do
    with {:ok, path} <- Workspace.resolve(dir, rel),
         {:ok, content} <- File.read(path) do
      fun.(content)
    else
      {:error, reason} when is_binary(reason) -> {false, reason}
      {:error, reason} -> {false, "#{rel}: #{inspect(reason)}"}
    end
  end

  defp with_json(dir, rel, fun) do
    with_file(dir, rel, fn content ->
      case decode(content) do
        {:ok, data} -> fun.(data)
        _ -> {false, "#{rel} is not valid JSON"}
      end
    end)
  end

  defp decode(nil), do: :error
  defp decode(content), do: Jason.decode(content)

  defp drop_path(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp drop_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, inner} when is_map(inner) -> Map.put(map, key, drop_path(inner, rest))
      _ -> map
    end
  end

  defp drop_path(other, _), do: other

  defp hit?(text, %Regex{} = re), do: Regex.match?(re, text)
  defp hit?(text, s) when is_binary(s), do: String.contains?(text, s)

  defp count(text, %Regex{} = re), do: length(Regex.scan(re, text))
  defp count(text, s) when is_binary(s), do: length(String.split(text, s)) - 1

  defp verdict(true, detail), do: {true, detail}
  defp verdict(false, detail), do: {false, "expected: " <> detail}

  defp show(%Regex{} = re), do: "~r/#{Regex.source(re)}/"
  defp show(s), do: inspect(s)

  defp describe(op) when is_tuple(op), do: op |> elem(0) |> Atom.to_string()
  defp describe(op), do: inspect(op)

  defp tail(out), do: out |> String.trim() |> String.slice(-300, 300)

  defp ok_or_nil({:ok, v}), do: v
  defp ok_or_nil(_), do: nil
end
