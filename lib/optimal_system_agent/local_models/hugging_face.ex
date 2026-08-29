defmodule OptimalSystemAgent.LocalModels.HuggingFace do
  @moduledoc """
  The little bit of the Hugging Face Hub API OSA needs to size a GGUF before
  pulling it: the repo's file list with byte sizes, and a search.

  Responses are cached on disk (`~/.osa/cache/hf/`) for a day — file sizes
  do not change, and the picker should not hit the network on every open.
  """

  @api "https://huggingface.co/api/models"
  @cache_ttl_s 24 * 3600

  @type quant_file :: %{quant: String.t(), bytes: non_neg_integer(), files: [String.t()]}

  @type repo :: %{
          id: String.t(),
          downloads: non_neg_integer(),
          tags: [String.t()],
          quants: [quant_file()],
          mmproj_bytes: non_neg_integer()
        }

  @doc """
  Repo metadata with every GGUF quant and its total size (split parts summed;
  the vision projector reported separately).
  """
  @spec repo(String.t(), keyword()) :: {:ok, repo()} | {:error, String.t()}
  def repo(repo_id, opts \\ []) when is_binary(repo_id) do
    with_cache("repo-" <> safe(repo_id), opts, fn ->
      case Req.get(
             [
               url: "#{@api}/#{repo_id}",
               params: [blobs: true],
               receive_timeout: 20_000,
               retry: false
             ] ++
               Keyword.get(opts, :req_opts, [])
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, parse_repo(body)}
        {:ok, %{status: 404}} -> {:error, "no such repo on Hugging Face: #{repo_id}"}
        {:ok, %{status: s}} -> {:error, "Hugging Face returned HTTP #{s}"}
        {:error, reason} -> {:error, "Hugging Face unreachable: #{inspect(reason)}"}
      end
    end)
  end

  @doc "Search the Hub for GGUF repos; `[%{id, downloads, likes}]` by downloads."
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 25)

    case Req.get(
           [
             url: @api,
             params: [search: query <> " GGUF", sort: "downloads", direction: -1, limit: limit],
             receive_timeout: 20_000,
             retry: false
           ] ++ Keyword.get(opts, :req_opts, [])
         ) do
      {:ok, %{status: 200, body: list}} when is_list(list) ->
        {:ok,
         list
         |> Enum.filter(&String.contains?(String.downcase(&1["id"] || ""), "gguf"))
         |> Enum.map(&%{id: &1["id"], downloads: &1["downloads"] || 0, likes: &1["likes"] || 0})}

      {:ok, %{status: s}} ->
        {:error, "Hugging Face returned HTTP #{s}"}

      {:error, reason} ->
        {:error, "Hugging Face unreachable: #{inspect(reason)}"}
    end
  end

  @doc "Parse an `/api/models/<id>?blobs=true` body (test seam)."
  @spec parse_repo(map()) :: repo()
  def parse_repo(body) do
    files =
      (body["siblings"] || [])
      |> Enum.map(&{&1["rfilename"] || "", &1["size"] || 0})
      |> Enum.filter(fn {name, _} -> String.ends_with?(String.downcase(name), ".gguf") end)

    {mmproj, weights} =
      Enum.split_with(files, fn {n, _} -> String.contains?(String.downcase(n), "mmproj") end)

    quants =
      weights
      |> Enum.group_by(fn {name, _} -> quant_of(name) end)
      |> Enum.reject(fn {q, _} -> is_nil(q) end)
      |> Enum.map(fn {q, fs} ->
        %{
          quant: q,
          bytes: Enum.sum(Enum.map(fs, &elem(&1, 1))),
          files: Enum.map(fs, &elem(&1, 0))
        }
      end)
      |> Enum.sort_by(& &1.bytes)

    %{
      id: body["id"] || body["modelId"] || "",
      downloads: body["downloads"] || 0,
      tags: body["tags"] || [],
      quants: quants,
      mmproj_bytes: mmproj |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    }
  end

  @doc "The quant label in a GGUF filename, e.g. `Q4_K_M`, `IQ4_XS`, `Q8_0`; nil if none."
  @spec quant_of(String.t()) :: String.t() | nil
  def quant_of(filename) do
    base = filename |> Path.basename() |> String.upcase()

    case Regex.run(
           ~r/(?:^|[-._])(IQ\d_[A-Z]+|Q\d_K_[SML]|Q\d_K|Q\d_\d|MXFP4|BF16|F16|F32)(?:[-._]|$)/,
           base
         ) do
      [_, q] -> q
      _ -> nil
    end
  end

  @doc "Pick the file group for `quant` (case-insensitive) from a parsed repo."
  @spec quant(repo(), String.t()) :: quant_file() | nil
  def quant(%{quants: quants}, wanted) do
    w = String.upcase(wanted)
    Enum.find(quants, &(&1.quant == w))
  end

  # ── cache ───────────────────────────────────────────────────────────────

  defp with_cache(key, opts, fun) do
    path = Path.join(cache_dir(), key <> ".json")

    fresh? =
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: m}} -> System.os_time(:second) - m < @cache_ttl_s
        _ -> false
      end

    with false <- Keyword.get(opts, :refresh, false) == false and fresh? and read_cache(path),
         {:ok, value} <- fun.() do
      write_cache(path, value)
      {:ok, value}
    else
      {:ok, cached} -> {:ok, cached}
      {:error, _} = e -> e
    end
  end

  defp read_cache(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, map} <- Jason.decode(raw, keys: :atoms) do
      {:ok, map}
    else
      _ -> false
    end
  end

  defp write_cache(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(value))
  rescue
    _ -> :ok
  end

  defp cache_dir do
    Application.get_env(:optimal_system_agent, :hf_cache_dir) ||
      Path.join([
        System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa"),
        "cache",
        "hf"
      ])
  end

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")
end
