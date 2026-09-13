defmodule OptimalSystemAgent.LocalModels.Catalog do
  @moduledoc """
  The curated list of local GGUF models OSA offers in `/models`
  (`priv/models/local_catalog.json`).

  An entry names a Hugging Face repo and the quants it ships; the Ollama tag
  for a pull is `hf.co/<repo>:<quant>`. Users can add their own entries in
  `~/.osa/local_catalog.json` (same shape) — those are merged on top, and an
  entry with the same `id` overrides the shipped one.
  """

  @type entry :: %{
          id: String.t(),
          name: String.t(),
          repo: String.t(),
          family: String.t() | nil,
          params_b: number(),
          active_params_b: number() | nil,
          quant: String.t(),
          quants: [String.t()],
          capabilities: [String.t()],
          context: non_neg_integer() | nil,
          tags: [String.t()],
          blurb: String.t(),
          source: :shipped | :user
        }

  @spec all() :: [entry()]
  def all do
    shipped = load(shipped_path(), :shipped)
    user = load(user_path(), :user)

    (shipped ++ user)
    |> Enum.reduce(%{}, fn e, acc -> Map.put(acc, e.id, e) end)
    |> Map.values()
    |> Enum.sort_by(&{&1.params_b, &1.name})
  end

  @doc "Find by catalog id, exact repo, or the `hf.co/<repo>:<quant>` tag."
  @spec find(String.t()) :: entry() | nil
  def find(ref) when is_binary(ref) do
    ref = String.trim(ref)
    {repo, _quant} = split_tag(ref)

    Enum.find(all(), fn e ->
      e.id == ref or e.repo == ref or String.downcase(e.repo) == String.downcase(repo)
    end)
  end

  @doc "Ollama tag for a catalog entry at `quant` (default: the entry's recommended quant)."
  @spec tag(entry(), String.t() | nil) :: String.t()
  def tag(entry, quant \\ nil), do: "hf.co/#{entry.repo}:#{quant || entry.quant}"

  @doc "`{repo, quant}` from `hf.co/<repo>:<quant>`, `<repo>:<quant>`, or a bare repo."
  @spec split_tag(String.t()) :: {String.t(), String.t() | nil}
  def split_tag(ref) do
    ref = String.replace_prefix(ref, "hf.co/", "") |> String.replace_prefix("huggingface.co/", "")

    case String.split(ref, ":", parts: 2) do
      [repo, quant] -> {repo, quant}
      [repo] -> {repo, nil}
    end
  end

  @doc "True when a tag is a Hugging Face pull (`hf.co/…`)."
  @spec hf_tag?(String.t()) :: boolean()
  def hf_tag?(tag), do: String.starts_with?(tag, ["hf.co/", "huggingface.co/"])

  @doc "The catalog entry an INSTALLED tag came from, if any."
  @spec entry_for_tag(String.t()) :: entry() | nil
  def entry_for_tag(tag) when is_binary(tag) do
    if hf_tag?(tag), do: find(tag), else: nil
  end

  defp shipped_path,
    do: Path.join(:code.priv_dir(:optimal_system_agent), "models/local_catalog.json")

  defp user_path do
    Application.get_env(:optimal_system_agent, :local_catalog_user_path) ||
      Path.join(
        System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa"),
        "local_catalog.json"
      )
  end

  defp load(path, source) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"models" => models}} when is_list(models) <- Jason.decode(raw) do
      models |> Enum.map(&normalize(&1, source)) |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  defp normalize(%{"repo" => repo} = m, source) when is_binary(repo) do
    %{
      id: m["id"] || repo |> String.split("/") |> List.last() |> String.downcase(),
      name: m["name"] || repo,
      repo: repo,
      family: m["family"],
      params_b: num(m["params_b"]) || 0,
      active_params_b: num(m["active_params_b"]),
      quant: m["quant"] || List.first(m["quants"] || []) || "Q4_K_M",
      quants: m["quants"] || [m["quant"] || "Q4_K_M"],
      capabilities: m["capabilities"] || [],
      context: m["context"],
      tags: m["tags"] || [],
      blurb: m["blurb"] || "",
      source: source
    }
  end

  defp normalize(_, _), do: nil

  defp num(n) when is_number(n), do: n
  defp num(_), do: nil
end
