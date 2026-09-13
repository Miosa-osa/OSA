defmodule OptimalSystemAgent.Security.FixVerify do
  @moduledoc """
  Re-run an injectable CHECKER after a code fix and compare before/after.

  The checker is not an exploit payload runner. It is `fn finding, files ->
  {:vulnerable, reason} | {:fixed, reason} | {:error, reason}` (injected as
  `fn phase, finding, opts`).

  `verified_fixed?` is true only when the before check is `:vulnerable` and
  the after check is `:fixed`.
  """

  @type status :: :vulnerable | :fixed | :unknown

  @type result :: %{
          finding_key: String.t(),
          before: status(),
          after: status(),
          verified_fixed?: boolean(),
          reason: String.t()
        }

  @type checker_result ::
          {:vulnerable, String.t()}
          | {:fixed, String.t()}
          | {:unknown, String.t()}
          | {:error, String.t()}

  @type checker :: (:before | :after, map(), keyword() -> checker_result())

  @doc """
  Run the checker before a fix, optionally apply `fix_after` once, then
  run the checker again.

  Options:

    * `:checker` - 3-arity fun. Inject in tests. Defaults to a static
      sink-presence check against `finding.sink` (or `poc`) in `file_path`
      (or `path`).
    * `:fix` - optional `%{file_path, fix_before, fix_after}`.
    * `:apply` - when true, replace `fix_before` with `fix_after` once
      (same algorithm as `CodeFixPr`). Default `false`.
  """
  @spec verify(map(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def verify(finding, opts \\ [])

  def verify(finding, opts) when is_map(finding) and is_list(opts) do
    apply? = Keyword.get(opts, :apply, false)
    fix = Keyword.get(opts, :fix)

    with {:ok, checker} <- resolve_checker(opts),
         {:ok, {before_status, before_reason}} <- run_checker(checker, :before, finding, opts),
         :ok <- maybe_apply(fix, apply?),
         {:ok, {after_status, after_reason}} <- run_checker(checker, :after, finding, opts) do
      {:ok,
       %{
         finding_key: finding_key(finding),
         before: before_status,
         after: after_status,
         verified_fixed?: before_status == :vulnerable and after_status == :fixed,
         reason: "before: #{before_reason}; after: #{after_reason}"
       }}
    end
  end

  def verify(_, _), do: {:error, "finding must be a map"}

  @doc """
  True when `needle` is not in the file contents. Missing file is false.
  Used as the default cheap checker.
  """
  @spec static_sink_gone?(String.t(), String.t()) :: boolean()
  def static_sink_gone?(path, needle) when is_binary(path) and is_binary(needle) do
    case File.read(path) do
      {:ok, contents} -> not String.contains?(contents, needle)
      _ -> false
    end
  end

  def static_sink_gone?(_, _), do: false

  # ── Checker ────────────────────────────────────────────────────────────

  defp resolve_checker(opts) do
    case Keyword.get(opts, :checker) do
      nil ->
        {:ok, &default_checker/3}

      fun when is_function(fun, 3) ->
        {:ok, fun}

      _ ->
        {:error, "checker must be a 3-arity function"}
    end
  end

  defp run_checker(checker, phase, finding, opts) do
    case checker.(phase, finding, opts) do
      {:vulnerable, reason} -> {:ok, {:vulnerable, stringify(reason)}}
      {:fixed, reason} -> {:ok, {:fixed, stringify(reason)}}
      {:unknown, reason} -> {:ok, {:unknown, stringify(reason)}}
      {:error, reason} -> {:error, stringify(reason)}
      other -> {:error, "checker returned #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp default_checker(phase, finding, _opts) do
    needle = needle(finding)
    path = file_path(finding)

    case phase do
      :before -> default_before(path, needle)
      :after -> default_after(path, needle)
    end
  end

  defp default_before(_path, nil), do: {:unknown, "missing sink needle"}
  defp default_before(nil, _needle), do: {:unknown, "missing file path"}

  defp default_before(path, needle) do
    if contains_needle?(path, needle) do
      {:vulnerable, "sink present: #{needle}"}
    else
      {:unknown, "sink not present before check"}
    end
  end

  defp default_after(_path, nil), do: {:vulnerable, "missing sink needle"}
  defp default_after(nil, _needle), do: {:vulnerable, "missing file path"}

  defp default_after(path, needle) do
    if static_sink_gone?(path, needle) do
      {:fixed, "sink gone: #{needle}"}
    else
      {:vulnerable, "sink still present: #{needle}"}
    end
  end

  defp contains_needle?(path, needle) do
    case File.read(path) do
      {:ok, contents} -> String.contains?(contents, needle)
      _ -> false
    end
  end

  # ── Apply (CodeFixPr replace-once) ─────────────────────────────────────

  defp maybe_apply(_fix, false), do: :ok
  defp maybe_apply(nil, true), do: :ok

  defp maybe_apply(fix, true) when is_map(fix) do
    path = field(fix, :file_path)
    before = field(fix, :fix_before)
    afterc = field(fix, :fix_after) || ""
    replace_once(path, before, afterc)
    :ok
  end

  defp maybe_apply(_, _), do: :ok

  defp replace_once(path, before, afterc)
       when is_binary(path) and path != "" and is_binary(before) and before != "" and
              is_binary(afterc) do
    abs = Path.expand(path)

    if File.regular?(abs) do
      content = File.read!(abs)

      case String.split(content, before, parts: 2) do
        [_only] ->
          :skip

        [pre, post] ->
          File.write!(abs, pre <> afterc <> post)
          :ok
      end
    else
      :skip
    end
  rescue
    _ -> :skip
  end

  defp replace_once(_, _, _), do: :skip

  # ── Finding fields ─────────────────────────────────────────────────────

  defp finding_key(finding) do
    case field(finding, :finding_key) do
      key when is_binary(key) and key != "" -> key
      _ -> "unknown"
    end
  end

  defp needle(finding) do
    case field(finding, :sink) || field(finding, :poc) do
      n when is_binary(n) and n != "" -> n
      _ -> nil
    end
  end

  defp file_path(finding) do
    case field(finding, :file_path) || field(finding, :path) do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp stringify(reason) when is_binary(reason), do: reason
  defp stringify(reason), do: to_string(reason)
end
