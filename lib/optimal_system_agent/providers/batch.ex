defmodule OptimalSystemAgent.Providers.Batch do
  @moduledoc """
  OpenAI Batch API — asynchronous, ~50% cheaper chat completions.

  See https://platform.openai.com/docs/api-reference/batch.

  This module is the DEFERRED path for `:loose`, long-horizon work: submit a
  pile of chat-completion requests as a JSONL file, get back a batch id, poll
  until the batch completes, then download the results. OpenAI's turnaround
  window is 24h, and the price is roughly half the synchronous rate — the trade
  is latency for cost.

  > #### NOT wired into the ReAct loop {: .warning}
  >
  > A ~24h async turnaround does not fit a synchronous agent turn, so this
  > capability is entirely opt-in and is NOT called from `Agent.Loop`,
  > `Orchestrator`, `LLMClient`, or `DelegationRouter`. Nothing in the live
  > agent path submits, polls, or resumes a batch today.
  >
  > This is deliberately a self-contained foundation. A follow-up will add the
  > async `submit → poll → resume` orchestration that lets a `:loose` task park
  > work here and pick the results up on a later turn. Until then the only way
  > to reach this code is to call it directly.

  ## Public API

      # 1. Submit a list of chat-completion request bodies.
      {:ok, batch_id} = Batch.submit(requests, opts)

      # 2. Poll for status.
      {:ok, %{status: "in_progress", output_file_id: nil}} = Batch.status(batch_id, opts)

      # 3. Once completed, fetch and parse the results.
      {:ok, [%{custom_id: "req-0", response: %{...}}, ...]} = Batch.results(batch_id, opts)

  Each entry in `requests` is a chat-completion request body — the same map you
  would `POST /v1/chat/completions`, e.g.

      %{"model" => "gpt-4o", "messages" => [%{"role" => "user", "content" => "hi"}]}

  A `custom_id` is assigned per request (`"request-<index>"`) unless the request
  already carries one under `:custom_id` / `"custom_id"`; it is echoed back by
  `results/2` so callers can correlate outputs with inputs.

  ## HTTP injection

  The HTTP client is injectable via `opts[:http]` so tests never touch the
  network. The function receives a request descriptor and returns
  `{:ok, %{status: integer(), body: term()}}` or `{:error, reason}`:

      http = fn %{method: :post, url: url, headers: headers, json: json, multipart: mp} ->
        {:ok, %{status: 200, body: %{"id" => "batch_123"}}}
      end

      Batch.submit(requests, http: http)

  When `opts[:http]` is absent the default client uses `Req` and mirrors how
  `OpenAICompat` resolves `base_url` / `api_key` / headers for provider
  `:openai` (the only provider offering the Batch API).
  """

  require Logger

  alias OptimalSystemAgent.Providers.OpenAICompatProvider

  @completion_window "24h"
  @endpoint "/v1/chat/completions"

  @typedoc "A chat-completion request body, as posted to /v1/chat/completions."
  @type request_body :: map()

  @typedoc "One parsed result row from a completed batch."
  @type result_row :: %{custom_id: String.t(), response: map() | nil, error: map() | nil}

  @doc """
  Submit `requests` as a batch job.

  Uploads the requests as a JSONL file (`POST /v1/files`, purpose `"batch"`),
  then creates the batch (`POST /v1/batches`, `completion_window: "24h"`).

  Returns `{:ok, batch_id}` or `{:error, reason}`.
  """
  @spec submit([request_body()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def submit(requests, opts \\ []) when is_list(requests) do
    with {:ok, ctx} <- context(opts),
         jsonl <- build_jsonl(requests),
         {:ok, file_id} <- upload_file(jsonl, ctx),
         {:ok, batch_id} <- create_batch(file_id, ctx) do
      {:ok, batch_id}
    end
  end

  @doc """
  Fetch the status of a batch (`GET /v1/batches/:id`).

  Returns `{:ok, %{status: status, output_file_id: id_or_nil, error_file_id: id_or_nil, raw: body}}`
  where `status` is one of `"validating"`, `"in_progress"`, `"finalizing"`,
  `"completed"`, `"failed"`, `"expired"`, `"cancelling"`, `"cancelled"`.
  """
  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(batch_id, opts \\ []) when is_binary(batch_id) do
    with {:ok, ctx} <- context(opts),
         {:ok, body} <- get_batch(batch_id, ctx) do
      {:ok,
       %{
         status: body["status"],
         output_file_id: body["output_file_id"],
         error_file_id: body["error_file_id"],
         raw: body
       }}
    end
  end

  @doc """
  Fetch and parse the results of a COMPLETED batch.

  Reads the batch's status to find its `output_file_id`, downloads that file's
  content (`GET /v1/files/:id/content`), and parses the JSONL into a list of
  `%{custom_id: ..., response: ..., error: ...}` rows.

  Returns `{:error, {:not_completed, status}}` if the batch is not yet
  `"completed"`, and `{:error, {:batch_failed, status}}` for a terminal
  failure (`"failed"`, `"expired"`, `"cancelled"`).
  """
  @spec results(String.t(), keyword()) :: {:ok, [result_row()]} | {:error, term()}
  def results(batch_id, opts \\ []) when is_binary(batch_id) do
    with {:ok, ctx} <- context(opts),
         {:ok, body} <- get_batch(batch_id, ctx),
         {:ok, output_file_id} <- output_file_for(body),
         {:ok, content} <- get_file_content(output_file_id, ctx) do
      {:ok, parse_results(content)}
    end
  end

  # ── Internal steps ────────────────────────────────────────────────────────

  defp upload_file(jsonl, ctx) do
    request = %{
      method: :post,
      url: "#{ctx.base_url}/files",
      headers: ctx.headers,
      json: nil,
      multipart: %{
        "purpose" => "batch",
        # {filename, content_type, binary} — the default client renders this as
        # a file part; a mock can inspect the tuple directly.
        "file" => {"batchinput.jsonl", "application/jsonl", jsonl}
      }
    }

    case ctx.http.(request) do
      {:ok, %{status: status, body: %{"id" => file_id}}} when status in 200..299 ->
        {:ok, file_id}

      {:ok, %{status: status, body: body}} ->
        {:error, "Batch file upload failed (HTTP #{status}): #{error_message(body)}"}

      {:error, reason} ->
        {:error, "Batch file upload failed: #{inspect(reason)}"}
    end
  end

  defp create_batch(file_id, ctx) do
    request = %{
      method: :post,
      url: "#{ctx.base_url}/batches",
      headers: ctx.headers,
      json: %{
        "input_file_id" => file_id,
        "endpoint" => @endpoint,
        "completion_window" => @completion_window
      },
      multipart: nil
    }

    case ctx.http.(request) do
      {:ok, %{status: status, body: %{"id" => batch_id}}} when status in 200..299 ->
        {:ok, batch_id}

      {:ok, %{status: status, body: body}} ->
        {:error, "Batch create failed (HTTP #{status}): #{error_message(body)}"}

      {:error, reason} ->
        {:error, "Batch create failed: #{inspect(reason)}"}
    end
  end

  defp get_batch(batch_id, ctx) do
    request = %{
      method: :get,
      url: "#{ctx.base_url}/batches/#{batch_id}",
      headers: ctx.headers,
      json: nil,
      multipart: nil
    }

    case ctx.http.(request) do
      {:ok, %{status: status, body: %{"status" => _} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "Batch status fetch failed (HTTP #{status}): #{error_message(body)}"}

      {:error, reason} ->
        {:error, "Batch status fetch failed: #{inspect(reason)}"}
    end
  end

  defp get_file_content(file_id, ctx) do
    request = %{
      method: :get,
      url: "#{ctx.base_url}/files/#{file_id}/content",
      headers: ctx.headers,
      json: nil,
      multipart: nil
    }

    case ctx.http.(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, to_jsonl_string(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, "Batch output download failed (HTTP #{status}): #{error_message(body)}"}

      {:error, reason} ->
        {:error, "Batch output download failed: #{inspect(reason)}"}
    end
  end

  # A completed batch has an output file; a terminal failure does not, so name
  # the specific reason rather than returning a confusing "no output_file_id".
  defp output_file_for(%{"status" => "completed", "output_file_id" => id})
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp output_file_for(%{"status" => status})
       when status in ["failed", "expired", "cancelled", "cancelling"],
       do: {:error, {:batch_failed, status}}

  defp output_file_for(%{"status" => status}), do: {:error, {:not_completed, status}}

  defp output_file_for(_), do: {:error, {:not_completed, nil}}

  # ── JSONL encode/decode ─────────────────────────────────────────────────────

  @doc false
  # Build the batch input as one JSONL line per request. Each line is a batch
  # request object wrapping the chat-completion body under `body`, tagged with a
  # `custom_id` so results can be correlated back.
  @spec build_jsonl([request_body()]) :: String.t()
  def build_jsonl(requests) do
    requests
    |> Enum.with_index()
    |> Enum.map(fn {req, idx} ->
      %{
        "custom_id" => custom_id(req, idx),
        "method" => "POST",
        "url" => @endpoint,
        "body" => strip_custom_id(req)
      }
      |> Jason.encode!()
    end)
    |> Enum.join("\n")
  end

  defp custom_id(req, idx) when is_map(req) do
    case req[:custom_id] || req["custom_id"] do
      id when is_binary(id) and id != "" -> id
      _ -> "request-#{idx}"
    end
  end

  defp strip_custom_id(req) when is_map(req), do: Map.drop(req, [:custom_id, "custom_id"])
  defp strip_custom_id(req), do: req

  @doc false
  # Parse a JSONL batch output file into result rows. Each line is a batch
  # response object: `{custom_id, response: %{status_code, body}, error}`.
  @spec parse_results(String.t()) :: [result_row()]
  def parse_results(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = row} ->
          [
            %{
              custom_id: row["custom_id"],
              response: extract_response_body(row["response"]),
              error: row["error"]
            }
          ]

        _ ->
          # A malformed line is skipped rather than failing the whole download —
          # a partial output is still useful, and the row's absence is visible.
          Logger.warning("[Batch] skipping unparseable JSONL result line")
          []
      end
    end)
  end

  # OpenAI wraps the chat-completion body under response.body; hand callers the
  # completion body directly, falling back to the whole response when the shape
  # is unexpected.
  defp extract_response_body(%{"body" => body}), do: body
  defp extract_response_body(other), do: other

  defp to_jsonl_string(body) when is_binary(body), do: body
  # A mock may hand back already-decoded rows; re-encode to the JSONL the parser
  # expects so the same parse path is exercised.
  defp to_jsonl_string(rows) when is_list(rows) do
    rows |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
  end

  defp to_jsonl_string(other), do: inspect(other)

  # Pull a human-readable message out of an OpenAI error body, falling back to
  # an inspect of whatever shape arrived.
  defp error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp error_message(body) when is_binary(body), do: body
  defp error_message(body), do: inspect(body)

  # ── Context / credential resolution ─────────────────────────────────────────

  # Resolve base_url, api_key, headers, and the HTTP client for this call.
  # Mirrors OpenAICompatProvider's resolution for the one provider that offers
  # the Batch API (:openai). Never edits that module — only reads through its
  # public accessors.
  defp context(opts) do
    provider = Keyword.get(opts, :provider, :openai)

    if provider != :openai do
      {:error, "Batch API is only supported for provider :openai (got #{inspect(provider)})"}
    else
      base_url = Keyword.get(opts, :base_url) || OpenAICompatProvider.base_url(provider)
      http = Keyword.get(opts, :http) || (&default_http/1)

      case resolve_api_key(provider, opts) do
        {:ok, api_key} ->
          {:ok, %{base_url: base_url, http: http, headers: build_headers(api_key)}}

        {:error, _} = err ->
          err
      end
    end
  end

  # A test that injects `:http` and passes an explicit `:api_key` (or none) must
  # not depend on a real key being configured; only fall back to the live
  # resolver when no key was supplied.
  defp resolve_api_key(provider, opts) do
    case Keyword.get(opts, :api_key) || OpenAICompatProvider.resolved_api_key(provider) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, "API key not configured for provider #{provider}"}
    end
  end

  defp build_headers(api_key) do
    [{"Authorization", "Bearer #{api_key}"}]
  end

  # Default HTTP client. Translates the request descriptor into a Req call.
  # JSON bodies decode to maps; a file-content download returns a raw binary.
  defp default_http(%{method: method, url: url, headers: headers} = request) do
    opts =
      [headers: headers, receive_timeout: 120_000]
      |> put_body(request)

    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, opts)
      end

    case result do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp put_body(opts, %{multipart: mp}) when is_map(mp), do: Keyword.put(opts, :form_multipart, mp)
  defp put_body(opts, %{json: json}) when is_map(json), do: Keyword.put(opts, :json, json)
  defp put_body(opts, _), do: opts
end
