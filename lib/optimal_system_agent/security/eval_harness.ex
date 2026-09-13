defmodule OptimalSystemAgent.Security.EvalHarness do
  @moduledoc """
  Independent pentest eval harness.

  Scores a list of findings against a fixture catalog (precision, recall,
  F0.5). Local fixtures only. Not a vendor XBEN score, and not a live
  scanner.
  """

  @source_glob "**/*.{py,ex,exs,js,ts,tsx,rb,go,java,php,rs}"

  @doc """
  Load `catalog.json`. Returns the decoded map (string keys).
  """
  @spec load_catalog(String.t()) :: {:ok, map()} | {:error, String.t()}
  def load_catalog(path) when is_binary(path) and path != "" do
    cond do
      not File.regular?(path) ->
        {:error, "catalog not found: #{path}"}

      true ->
        with {:ok, body} <- File.read(path),
             {:ok, data} <- decode_json(body),
             :ok <- validate_catalog(data) do
          {:ok, data}
        end
    end
  end

  def load_catalog(_), do: {:error, "catalog path is required"}

  @doc """
  Score findings against a loaded catalog.

  A finding matches a case when classes are equal (atom or string) and the
  finding file basename matches `case.file`, or the finding has no file.
  """
  @spec score(map(), [map()]) :: map()
  def score(catalog, findings) when is_map(catalog) and is_list(findings) do
    cases = catalog_cases(catalog)

    by_id =
      Map.new(cases, fn caze ->
        matched? = Enum.any?(findings, &matches?(caze, &1))
        must? = must_find?(caze)

        label =
          cond do
            must? and matched? -> :tp
            must? and not matched? -> :fn
            not must? and matched? -> :fp
            true -> :tn
          end

        {case_id(caze), label}
      end)

    extra_fp =
      Enum.count(findings, fn finding ->
        not Enum.any?(cases, &matches?(&1, finding))
      end)

    tp = count_label(by_id, :tp)
    fn_count = count_label(by_id, :fn)
    fp = count_label(by_id, :fp) + extra_fp

    {precision, recall, f0_5} = metrics(tp, fp, fn_count)

    %{
      true_positives: tp,
      false_positives: fp,
      false_negatives: fn_count,
      precision: precision,
      recall: recall,
      f0_5: f0_5,
      by_id: by_id
    }
  end

  @doc """
  Load a catalog and score findings.

  Options:
    * `:catalog` - path to catalog.json (required)
    * `:findings` - list of finding maps (skips scanner when present)
    * `:scanner` - `fn root -> {:ok, [findings]} | {:error, reason}`
    * `:root` - fixture directory; required when scanning
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(opts) when is_list(opts) do
    with {:ok, catalog} <- load_catalog(Keyword.get(opts, :catalog)),
         {:ok, findings} <- resolve_findings(opts) do
      {:ok, score(catalog, findings)}
    end
  end

  def run(_), do: {:error, "options must be a keyword list"}

  defp resolve_findings(opts) do
    cond do
      is_list(Keyword.get(opts, :findings)) ->
        {:ok, Keyword.fetch!(opts, :findings)}

      is_function(Keyword.get(opts, :scanner), 1) ->
        invoke_scanner(Keyword.fetch!(opts, :scanner), Keyword.get(opts, :root))

      true ->
        default_scan(Keyword.get(opts, :root))
    end
  end

  defp invoke_scanner(scanner, root) when is_binary(root) do
    case scanner.(root) do
      {:ok, findings} when is_list(findings) -> {:ok, findings}
      {:error, reason} -> {:error, to_reason(reason)}
      findings when is_list(findings) -> {:ok, findings}
      other -> {:error, "scanner returned #{inspect(other)}"}
    end
  end

  defp invoke_scanner(_scanner, _), do: {:error, "root is required"}

  # Cheap static pass: SELECT concat -> sqli, innerHTML -> xss. Not a pentest.
  defp default_scan(root) when is_binary(root) do
    if File.dir?(root) do
      {:ok, scan_tree(root)}
    else
      {:error, "root is required and must exist"}
    end
  end

  defp default_scan(_), do: {:error, "root is required"}

  defp scan_tree(root) do
    root
    |> Path.join(@source_glob)
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/.git/"))
    |> Enum.flat_map(&scan_file/1)
  end

  defp scan_file(path) do
    case File.read(path) do
      {:ok, content} ->
        file = Path.basename(path)

        []
        |> maybe_hit(sqli_concat?(content), %{class: "sqli", file: file})
        |> maybe_hit(xss_innerhtml?(content), %{class: "xss", file: file})

      _ ->
        []
    end
  end

  defp maybe_hit(acc, true, finding), do: acc ++ [finding]
  defp maybe_hit(acc, false, _finding), do: acc

  defp sqli_concat?(content) do
    Regex.match?(~r/SELECT/i, content) and
      Regex.match?(~r/["']\s*\+|concat\s*\(|\|\|/i, content)
  end

  defp xss_innerhtml?(content), do: String.contains?(content, "innerHTML")

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, err} -> {:error, "invalid catalog JSON: #{Exception.message(err)}"}
    end
  end

  defp validate_catalog(data) when is_map(data) do
    cases = catalog_cases(data)

    if is_list(cases) do
      :ok
    else
      {:error, "catalog cases must be a list"}
    end
  end

  defp validate_catalog(_), do: {:error, "catalog must be a JSON object"}

  defp catalog_cases(catalog) do
    field(catalog, :cases) || []
  end

  defp matches?(caze, finding) when is_map(finding) do
    class_eq?(case_class(caze), finding_class(finding)) and
      file_eq?(case_file(caze), finding_file(finding))
  end

  defp matches?(_caze, _finding), do: false

  defp class_eq?(nil, _), do: false
  defp class_eq?(_, nil), do: false
  defp class_eq?(a, b), do: normalize_class(a) == normalize_class(b)

  defp file_eq?(_case_file, file) when file in [nil, ""], do: true

  defp file_eq?(case_file, finding_file) do
    Path.basename(to_string(case_file || "")) == Path.basename(to_string(finding_file))
  end

  defp must_find?(caze) do
    case field(caze, :must_find) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp case_id(caze), do: to_string(field(caze, :id) || "")
  defp case_class(caze), do: field(caze, :class)
  defp case_file(caze), do: field(caze, :file)

  defp finding_class(finding), do: field(finding, :class) || field(finding, :vuln_class)

  defp finding_file(finding) do
    field(finding, :file) || field(finding, :source) || field(finding, :path)
  end

  defp normalize_class(value) when is_atom(value) do
    value |> Atom.to_string() |> String.downcase()
  end

  defp normalize_class(value) when is_binary(value), do: String.downcase(value)
  defp normalize_class(value), do: value |> to_string() |> String.downcase()

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp count_label(by_id, label) do
    Enum.count(by_id, fn {_id, v} -> v == label end)
  end

  defp metrics(tp, fp, fn_count) do
    precision = ratio(tp, tp + fp)
    recall = ratio(tp, tp + fn_count)
    {precision, recall, f_beta(precision, recall, 0.5)}
  end

  defp ratio(_n, 0), do: 0.0
  defp ratio(n, d), do: n / d

  defp f_beta(precision, recall, beta) do
    b2 = beta * beta
    denom = b2 * precision + recall

    if denom == 0.0 do
      0.0
    else
      (1 + b2) * precision * recall / denom
    end
  end

  defp to_reason(reason) when is_binary(reason), do: reason
  defp to_reason(reason), do: inspect(reason)
end
