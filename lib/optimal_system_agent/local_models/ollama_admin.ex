defmodule OptimalSystemAgent.LocalModels.OllamaAdmin do
  @moduledoc """
  Management side of the local Ollama daemon: what is installed, what is
  loaded in VRAM, pull / delete / alias, load / unload, and a short decode
  benchmark. The chat side lives in `Providers.Ollama`; this module never
  generates a reply.

  Every call goes to `Providers.Ollama.local_daemon_url/0` — the daemon on
  THIS machine, regardless of what `OLLAMA_URL` says.
  """

  alias OptimalSystemAgent.Providers.Ollama

  @type installed :: %{
          name: String.t(),
          size_bytes: non_neg_integer(),
          modified: String.t() | nil,
          family: String.t() | nil,
          params: String.t() | nil,
          quant: String.t() | nil,
          digest: String.t() | nil,
          remote: boolean()
        }

  @type loaded :: %{
          name: String.t(),
          size_bytes: non_neg_integer(),
          vram_bytes: non_neg_integer(),
          expires_at: String.t() | nil
        }

  @type details :: %{
          name: String.t(),
          capabilities: [String.t()],
          family: String.t() | nil,
          params: String.t() | nil,
          quant: String.t() | nil,
          context_length: non_neg_integer() | nil,
          params_count: non_neg_integer() | nil,
          kv_bytes_per_token: non_neg_integer() | nil,
          model_info: map()
        }

  @spec url() :: String.t()
  def url, do: Ollama.local_daemon_url()

  # ── read ────────────────────────────────────────────────────────────────

  @doc "Models the daemon has on disk (`/api/tags`). Cloud tags are flagged `remote`."
  @spec installed(keyword()) :: {:ok, [installed()]} | {:error, String.t()}
  def installed(req_opts \\ []) do
    case get("/api/tags", req_opts) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok,
         Enum.map(models, fn m ->
           d = m["details"] || %{}

           name = m["name"] || m["model"]

           %{
             name: name,
             size_bytes: m["size"] || 0,
             modified: m["modified_at"],
             family: d["family"],
             params: d["parameter_size"],
             quant: quant_of(d["quantization_level"], name),
             digest: m["digest"],
             remote: is_binary(m["remote_host"]) or cloud_tag?(name || "")
           }
         end)}

      other ->
        err(other)
    end
  end

  @doc "Models currently resident (`/api/ps`)."
  @spec loaded(keyword()) :: {:ok, [loaded()]} | {:error, String.t()}
  def loaded(req_opts \\ []) do
    case get("/api/ps", req_opts) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok,
         Enum.map(models, fn m ->
           %{
             name: m["name"] || m["model"],
             size_bytes: m["size"] || 0,
             vram_bytes: m["size_vram"] || 0,
             expires_at: m["expires_at"]
           }
         end)}

      other ->
        err(other)
    end
  end

  @doc "Capabilities and GGUF metadata for one installed model (`/api/show`)."
  @spec show(String.t(), keyword()) :: {:ok, details()} | {:error, String.t()}
  def show(name, req_opts \\ []) when is_binary(name) do
    case post("/api/show", %{model: name}, req_opts) do
      {:ok, %{} = body} ->
        d = body["details"] || %{}
        info = body["model_info"] || %{}
        arch = info["general.architecture"]

        {:ok,
         %{
           name: name,
           capabilities: body["capabilities"] || [],
           family: d["family"] || arch,
           params: d["parameter_size"],
           quant: d["quantization_level"],
           context_length: if(is_binary(arch), do: info["#{arch}.context_length"]),
           params_count: info["general.parameter_count"],
           kv_bytes_per_token: OptimalSystemAgent.LocalModels.Fit.kv_from_model_info(info),
           model_info: info
         }}

      other ->
        err(other)
    end
  end

  # ── write ───────────────────────────────────────────────────────────────

  @doc """
  Pull a model, streaming progress to `on_progress` as
  `%{status, completed, total}` maps. Blocks until done. A pull that Ollama
  reports as an error (bad tag, no such quant, no space) is returned as
  `{:error, message}`.
  """
  @spec pull(String.t(), (map() -> any()), keyword()) :: :ok | {:error, String.t()}
  def pull(name, on_progress \\ fn _ -> :ok end, req_opts \\ []) when is_binary(name) do
    acc = %{buffer: "", error: nil, done: false}

    result =
      Req.post(
        [
          url: url() <> "/api/pull",
          json: %{model: name, stream: true},
          receive_timeout: :timer.hours(6),
          retry: false,
          into: fn {:data, data}, {req, resp} ->
            state = Process.get(:osa_pull_acc, acc)
            {lines, rest} = split_lines(state.buffer <> data)

            state =
              Enum.reduce(lines, %{state | buffer: rest}, fn line, st ->
                case Jason.decode(line) do
                  {:ok, %{"error" => e}} ->
                    %{st | error: to_string(e)}

                  {:ok, %{"status" => status} = ev} ->
                    on_progress.(%{
                      status: status,
                      completed: ev["completed"] || 0,
                      total: ev["total"] || 0
                    })

                    if status == "success", do: %{st | done: true}, else: st

                  _ ->
                    st
                end
              end)

            Process.put(:osa_pull_acc, state)
            {:cont, {req, resp}}
          end
        ] ++ req_opts
      )

    state = Process.get(:osa_pull_acc, acc)
    Process.delete(:osa_pull_acc)

    case {result, state} do
      {_, %{error: e}} when is_binary(e) -> {:error, e}
      {{:ok, %{status: 200}}, %{done: true}} -> :ok
      {{:ok, %{status: 200}}, _} -> {:error, "pull ended without success status"}
      {{:ok, %{status: s}}, _} -> {:error, "HTTP #{s}"}
      {{:error, reason}, _} -> {:error, describe(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Remove a model from disk (`/api/delete`)."
  @spec delete(String.t(), keyword()) :: :ok | {:error, String.t()}
  def delete(name, req_opts \\ []) when is_binary(name) do
    case request(:delete, "/api/delete", %{model: name}, req_opts) do
      {:ok, _} -> :ok
      other -> err(other)
    end
  end

  @doc "Add a second tag for a model, sharing its blobs (`/api/copy`)."
  @spec copy(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def copy(from, to, req_opts \\ []) when is_binary(from) and is_binary(to) do
    case post("/api/copy", %{source: from, destination: to}, req_opts) do
      {:ok, _} -> :ok
      other -> err(other)
    end
  end

  @doc "Load into VRAM and keep it there (`keep_alive: -1`) without generating."
  @spec load(String.t(), keyword()) :: :ok | {:error, String.t()}
  def load(name, req_opts \\ []) when is_binary(name) do
    case post(
           "/api/generate",
           %{model: name, keep_alive: -1},
           req_opts ++ [receive_timeout: :timer.minutes(5)]
         ) do
      {:ok, _} -> :ok
      other -> err(other)
    end
  end

  @doc "Evict from VRAM now (`keep_alive: 0`)."
  @spec unload(String.t(), keyword()) :: :ok | {:error, String.t()}
  def unload(name, req_opts \\ []) when is_binary(name) do
    case post("/api/generate", %{model: name, keep_alive: 0}, req_opts) do
      {:ok, _} -> :ok
      other -> err(other)
    end
  end

  @doc """
  Measured decode speed: generate `n` tokens and read Ollama's own timing
  (`eval_count / eval_duration`). Returns tokens/s for decode and prompt
  processing, plus load time. Loads the model if it is not resident.
  """
  @spec bench(String.t(), pos_integer(), keyword()) ::
          {:ok, %{decode_tps: float(), prompt_tps: float() | nil, load_ms: non_neg_integer()}}
          | {:error, String.t()}
  def bench(name, n \\ 64, req_opts \\ []) when is_binary(name) do
    body = %{
      model: name,
      prompt: "Write a long, detailed paragraph about the history of computing.",
      stream: false,
      options: %{num_predict: n, temperature: 0},
      think: false
    }

    case post("/api/generate", body, req_opts ++ [receive_timeout: :timer.minutes(10)]) do
      {:ok, %{"eval_count" => count, "eval_duration" => dur} = r}
      when is_integer(count) and is_integer(dur) and dur > 0 ->
        prompt_tps =
          case {r["prompt_eval_count"], r["prompt_eval_duration"]} do
            {c, d} when is_integer(c) and is_integer(d) and d > 0 ->
              Float.round(c / (d / 1.0e9), 1)

            _ ->
              nil
          end

        {:ok,
         %{
           decode_tps: Float.round(count / (dur / 1.0e9), 1),
           prompt_tps: prompt_tps,
           load_ms: div(r["load_duration"] || 0, 1_000_000)
         }}

      {:ok, _} ->
        {:error, "no timing in response"}

      other ->
        err(other)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp get(path, req_opts) do
    request(:get, path, nil, req_opts)
  end

  defp post(path, body, req_opts) do
    request(:post, path, body, req_opts)
  end

  defp request(method, path, body, req_opts) do
    opts =
      [method: method, url: url() <> path, receive_timeout: 15_000, retry: false] ++
        if(body, do: [json: body], else: []) ++ req_opts

    case Req.request(opts) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
      {:ok, %{status: s, body: %{"error" => e}}} -> {:error, "HTTP #{s}: #{e}"}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, describe(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp err({:error, msg}) when is_binary(msg), do: {:error, msg}
  defp err(other), do: {:error, inspect(other)}

  defp describe(%{reason: :econnrefused}), do: "Ollama is not running at #{url()}"
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(other), do: inspect(other)

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp cloud_tag?(name), do: OptimalSystemAgent.Providers.OllamaCloud.cloud_tag?(name)

  # Ollama reports `unknown` for a GGUF pulled from Hugging Face; the quant is
  # in the tag (`hf.co/<repo>:Q4_K_M`).
  defp quant_of(level, name) when level in [nil, "", "unknown"] and is_binary(name) do
    case OptimalSystemAgent.LocalModels.Catalog.split_tag(name) do
      {_, q} when is_binary(q) and q != "latest" -> String.upcase(q)
      _ -> nil
    end
  end

  defp quant_of(level, _name), do: level
end
